function [R, wls, zpos, ts, par, sigMat, spar, r_sensor] = reconMSOT(fn,varargin)
% [R wls zpos ts] = reconMSOT(fn,parameters[,verbose]);
% 
% Reconstruction function to reconstruct a selected dataset using the
% supplied parameters
%
% Input Parameters:
% -----------------
% - Filename: Either filename of .msot file or datainfo object
% - Parameters: (struct)
%   n            -> Resolution (default: 200)
%   proj         -> Number of Projections (default: 2*number of detectors)
%   c            -> Speed of Sound (either absolute or offset, default: 0)
%   roi          -> Region of Interest (in cm, default: 20)
%   image_select -> Reconstruction algorithm (*direct, model_lin, wavelet)
%   filter_f     -> Bandpass frequencies (default: 50kHz - 7Mhz)
%   iter         -> LSQR Iterations for 'model_lin'
%   timeres      -> Timeresolution for 'model_lin' and 'wavelet'
%   selMat       -> Selection Matrix based on datainfo.ScanStructure
%   progress     -> Show progress window (default: true);
% - Verbose: Print verbose logging information (true/false)
%
% Return Values:
% --------------
% @return R          An array containing the reconstructed images in 8D
%                    1) x
%                    2) y
%                    3) z (only if 3D detector, currently unused)
%                    4) RUN (repetition of the whole acquisition step, time
%                       dimension (timepoints as separate vector)
%                    5) z-position (if 2D system with translation stage)
%                    6) REPETITION (currently unused)
%                    7) Wavelength (see wls vector)
%                    8) Individual Images (only if not averaged)
% @return wls        Wavelength Vector
% @return zpos       Array of z-stage positions
% @return ts         Multidimensional array of timestamps in s, same 
%                    dimension as R

%% Input Parameters
% Filename
sigMat = [];
spar = struct;
if (isstruct(fn) || isa(fn,'msotData'))
    datainfo = fn;
    fn = datainfo.XMLFileName;
else
    if (~exist(fn,'file'))
      error(['MSOT File not found: ' fn]);
    else 
        datainfo = loadMSOT(fn);
    end
end

% Parameter default set
if (exist('getWLdefaults')),
    par = getWLdefaults;
else
    par = struct;
end

par.n = 200;
par.proj = datainfo.HWDesc.NumDetectors*2-1;
par.r_sensor = datainfo.HWDesc.Radius;
par.r_offset = 0;
par.c = 0;
par.roi = 20e-3;
par.roiZ = 30e-3;
par.YOffset = [];
par.image_select = 'direct';
par.filter_f = [125 7500]*1e3;
par.filter_rise = 0.8;          % percentage of rise and fall of FIR filter
par.filter_imag = true;        % default: use non imaginary part for filter design
par.filter_ramp = true;
% par.filter_irphase = true;
par.iter = 50;
par.timeres = 3;
par.n_angles = par.n*2;
par.limitSensors = [];
par.swapSensors = [];
par.angle_sensor = [];
par.angle_offset = 0;
par.selMat = datainfo.ScanStructure;
par.Amat_dir = 'E:\_Amatrices';
par.f_HPFOrder = 4;
par.f_HPFRipple = 0.01;
par.f_HPFzp = 1;
par.mirror = false; % mirror image (0: none, true/3: both axis, 1: x, 2: y)
par.save = 0;       % 2: save in matlab file
par.progress = true;
par.useGPU = 0;     % use GPU for backprojection (requires itheract.cl)
par.laserCorrection = false;

% GPU only
par.impresp = [];   % will be loaded automatically if included w scan, put
                    % 0 if desired to NOT include IR




% Copy parameters from input struct
if numel(varargin) >= 1
    cpar = varargin{1};
    % transfer all fields to parameter array
    fx = fieldnames(cpar);
    for j = 1:numel(fx)
        par = setfield(par,fx{j},getfield(cpar,fx{j}));
    end
    clear cpar j fx;
end

if numel(varargin) >= 2
    verbose = varargin{2};
end

if numel(varargin) >= 3
    sigMat = varargin{3};
    if numel(par.selMat) == numel(datainfo.ScanStructure);
        svec = size(sigMat);
        if numel(svec) <= 3, svec = [svec ones(1,4-numel(svec))]; end;
        par.selMat = reshape(1:prod(svec(3:end)),svec(3:end));
        if (isempty(par.selMat)), par.selMat = 1; end;
    end
else
    sigMat = [];
end

%% check GPU environment
if par.useGPU,
  clfile = which('itheract.cl');        % find on path
  if ~isempty(clfile),
      [clpath,~] = fileparts(clfile);
      setenv('ITHERAFILES1',clpath);
  end
  if ~isempty(getenv('ITHERAFILES1')),  % if directory specified, this overrides
      clpath = getenv('ITHERAFILES1');
      setenv('ITHERAFILES1',clpath);
      clfile = [clpath '\itheract.cl'];
  end
  if isempty(clfile) || exist(clfile,'file') == 0,
      error(['itheract.cl is not found on your path (' clfile ')']);
  end
  
  if exist('startupcl','file') ~= 3,
      error('startupcl.mexw64 is not on your path\n');
  end
  if exist('BackProjectionSetup_cl','file') ~= 3,
      error('BackProjectionSetup_cl.mexw64 is not on your path\n');
  end
  if exist('setsensorspectrachannels_cl','file') ~= 3,
      error('setsensorspectrachannels_cl.mexw64 is not on your path\n');
  end
  if exist('DeconvInterpRecon2D_cl','file') ~= 3,
      error('DeconvInterpRecon2D_cl.mexw64 is not on your path\n');
  end
end

%% derived parameters
if isempty(par.YOffset), par.YOffset = -par.roiZ/2; end

ires = par.roi / par.n;
par.nz = round(par.roiZ / ires);


%% load signal Data
% to be safe, cast as double if usePower is 0...
if isempty(sigMat),
    [sigMat,~,selMat,spar] = loadMSOTSignals(datainfo,par.selMat,par);
    sigMat = double(sigMat);
else
    selMat = par.selMat; 
end
% ts = datainfo.RelTime(selMat);

% put selMat to 1D 
sigMat = reshape(sigMat,size(sigMat,1),size(sigMat,2),numel(selMat));
svec = size(selMat);
selMat = reshape(selMat,numel(selMat),1);


%% preprocess signals
[sigMat, t, angle_sensor] = preprocessSignals(sigMat,datainfo,par);

if par.swapSensors
    angle_sensor = angle_sensor(par.swapSensors);
end

%% load impulse response
if par.impresp == 0, % avoid impresp
    par.impresp = [];
elseif ischar(par.impresp) || isempty(par.impresp),
    if ischar(par.impresp),
        irpath = par.impresp;
    else
        irpath = strrep((datainfo.XMLFileName),'msot','irf');
    end
    
    if exist(irpath,'file'),
        FID = fopen(irpath);
        par.impresp = fread(FID,'double')';
        fclose(FID);
        if par.progress, fprintf('Electrical Impulse Response loaded (%s)\n',irpath); end
    else 
        par.impresp = [];
    end
end

if isempty(par.impresp) && par.progress,
   fprintf('No Electrical Impulse Response used\n');
end    

%% preparation
if size(angle_sensor,2) == 3,
    r_sensor = angle_sensor;
else
    r_sensor = [ cos( angle_sensor' ) sin( angle_sensor' ) zeros( size( angle_sensor' ) ) ];
    r_sensor = r_sensor .* ( (ones(numel(angle_sensor),1) .* par.r_sensor + par.r_offset) * ones(1,3) );
end
fs = datainfo.HWDesc.SamplingFrequency;
if datainfo.is3D,
    if strcmp(par.image_select,'direct'),
        if par.useGPU,
            limits(1) = par.r_sensor - par.roi/2;       % x low
            limits(2) = par.r_sensor + par.roi/2;       % x high
            limits(3) = par.YOffset;                    % FoV start
            limits(4) = limits(3) + par.roiZ(1);        % FOV end
            
            filterSpec.frequencyMultiplier = [1,1];
            filterSpec.filterType = [0,0];              
            filterSpec.zerophase = [0,0];               % unused
            filterSpec.order = [1,1];                   % unused
            filterSpec.rp = [0.1,0.1];                  % unused
            filterSpec.rs = [0,0];                      % unused
            f1=par.filter_f(1)*1e-6;
            f2=par.filter_f(2)*1e-6;
            if (f2 == 0), f2 = 12; end;
            f3 = 0.2*f2;
            ampmin = 0.0+(1/20*f1);
            ampmax = 0.0+(1/20*f2);
            amp = 1i;

            filterSpec.freqVec = [0.0, par.filter_rise*f1, f1,  f2, f2+f3, 20]/20;   % frequency
            filterSpec.ampVec =  [0.0, 0.0, ampmin, ampmax, 0.0, 0.0].*amp;       

            % start CL
            if (getenv('ITHERA_CL_VENDOR')),
                startupcl('vendor',getenv('ITHERA_CL_VENDOR'),'type',getenv('ITHERA_CL_TYPE'));
            else
                startupcl('vendor','amd','type','gpu');
            end

            par.filter_irphase = true;
            % prepare CL
            
            [r_sensor, par.corrvec] = BackProjectionSetup_cl( par.impresp, double(r_sensor), [], ...
                datainfo.HWDesc.NumDetectors, datainfo.HWDesc.NumDetectors, fs, par.filter_f, limits, filterSpec);
            setsensorspectrachannels_cl(par.corrvec,datainfo.HWDesc.NumDetectors);

            sigMat = sigMat - min(sigMat(:));   % remove negatives
            fac = floor((2.^16)./max(sigMat(:)));
           
        else
            error('3D Reconstruction only supported for GPU mode (par.useGPU = 1)');
        end
    else
        error('3D reconstruction is only supported for direct BP at this time');
    end
else
    % backprojection
    if strcmp(par.image_select,'direct')
        % special GPU preparations
        if par.useGPU,
            limits(1) = par.r_sensor - par.roi/2;       % x low
            limits(2) = par.r_sensor + par.roi/2;       % x high

            filterSpec.frequencyMultiplier = [1,1];
            filterSpec.filterType = [0,0];              
            filterSpec.zerophase = [0,0];               % unused
            filterSpec.order = [1,1];                   % unused
            filterSpec.rp = [0.1,0.1];                  % unused
            filterSpec.rs = [0,0];                      % unused
            f1=par.filter_f(1)*1e-6;
            f2=par.filter_f(2)*1e-6;
            if (f2 == 0), f2 = 12; end;
            f3 = 0.2*f2;

            ampmin = (1/20*f1);
            ampmax = (1/20*f2);
            if par.filter_ramp,
                if par.filter_imag,
                    ampmin = ampmin*1i; ampmax = ampmax*1i;
                else
                    ampmin = ampmin+ampmin*1i; ampmax = ampmax+ampmax*1i;
                end
            else
                if par.filter_imag,
                    ampmin = 1.0+1i; ampmax = 1.0+1i;
                else
                    ampmin = 1; ampmax = 1;
                end
            end

            filterSpec.freqVec = [0.0, par.filter_rise*f1, f1,  f2, f2+f3, 20]/20;   % frequency
            filterSpec.ampVec =  [0.0, 0.0, ampmin, ampmax, 0.0, 0.0];         
            par.filterSpec = filterSpec;

            % start CL
            if (getenv('ITHERA_CL_VENDOR')),
                startupcl('vendor',getenv('ITHERA_CL_VENDOR'),'type',getenv('ITHERA_CL_TYPE'));
            else
                startupcl('vendor','amd','type','gpu');
            end


% no phase change
% [r_sensor, gB] = BackProjectionSetup_cl( [], double(pos_elements), [], ...
%     num_channels, proj, fs, [0,0], limits, filterSpec);
% filterSpecA=filterSpec;
% filterSpec.freqVec = [0.0, f1-f3, f1, f2,f2+f4, 20]/20;   % frequency                   
% filterSpecA.ampVec = [0.0, 0.0, 1, 1,0.0, 0.0]; 
% [r_sensor, gA] = BackProjectionSetup_cl( IRF, double(pos_elements), [], ...
%     num_channels, proj, fs, [0,0], limits, filterSpecA);
% g=1i.*single(abs(gA).*imag(gB));
            
%             if par.filter_irphase,
                [r_sensor, par.corrvec] = BackProjectionSetup_cl( par.impresp, double(r_sensor), [], ...
                    size(sigMat,2), par.proj, fs, par.filter_f, limits, filterSpec);
%             else
%                 filterSpecA=filterSpec;
%                 filterSpecA.ampVec = [0.0, 0.0, 1, 1,0.0, 0.0]; 
%                 [r_sensor, cv_noir] = BackProjectionSetup_cl( [], double(r_sensor), [], ...
%                     size(sigMat,2), par.proj, fs, par.filter_f, limits, filterSpec);
%                 [r_sensor, cv] = BackProjectionSetup_cl( par.impresp, double(r_sensor), [], ...
%                     size(sigMat,2), par.proj, fs, par.filter_f, limits, filterSpecA);
%                 par.corrvec = complex(single(abs(cv)));
% %                    par.corrvec = 1i.*single(abs(cv).*imag(cv_noir));
%          end
% %%
%             figure;
%             subplot(3,2,1);
%             plot(abs(cv_noir(1:end/4)));hold all;
%             plot(real(cv_noir(1:end/4)));
%             plot(imag(cv_noir(1:end/4)));
%             legend({'abs','real','imag'});
% 
%             subplot(3,2,2);
%             plot((angle(cv_noir(1:end/4)))/pi);hold all;
% 
% 
%             subplot(3,2,3);
%             plot(abs(cv(1:end/4)));hold all;
%             plot(real(cv(1:end/4)));
%             plot(imag(cv(1:end/4)));
%             legend({'abs','real','imag'});
%             subplot(3,2,4);
%             plot((angle(cv(1:end/4)))/pi);hold all;
% 
%             subplot(3,2,5);
%             plot(abs(par.corrvec(1:end/4)));hold all;
%             plot(real(par.corrvec(1:end/4)));
%             plot(imag(par.corrvec(1:end/4)));
%             legend({'abs','real','imag'});
%             subplot(3,2,6);
%             plot((angle(par.corrvec(1:end/4)))/pi);hold all;

  %%          
            setsensorspectrachannels_cl(par.corrvec,size(sigMat,2));
            
            % prepare CL
%             [r_sensor, par.corrvec] = BackProjectionSetup_cl( par.impresp, double(r_sensor), [], ...
%                 size(sigMat,2), par.proj, fs, par.filter_f, limits, filterSpec);
%             setsensorspectrachannels_cl(par.corrvec,size(sigMat,2));

            sigMat = sigMat - min(sigMat(:));   % remove negatives
            fac = floor((2.^16)./max(sigMat(:)));
        end
    % model based
    elseif (strcmp(par.image_select,'model_lin'))
        % average speed of sound
         if (par.c < 1000)
            T = datainfo.AverageTemperature;
            par.c = round(1.402385 * 1e3 + 5.038813 * T - 5.799136 * 1e-2 * T^2 + 3.287156 * 1e-4 * T^3 - 1.398845 * 1e-6 * T^4 + 2.787860 * 1e-9 * T^5 + par.c); 
        else 
            par.c = round(par.c);
        end
       A_mat = getAMat(par,angle_sensor,t);
    % wavelet model based
    elseif (strcmp(par.image_select,'wavelet'))
        % average speed of sound
         if (par.c < 1000)
            T = datainfo.AverageTemperature;
            par.c = round(1.402385 * 1e3 + 5.038813 * T - 5.799136 * 1e-2 * T^2 + 3.287156 * 1e-4 * T^3 - 1.398845 * 1e-6 * T^4 + 2.787860 * 1e-9 * T^5 + par.c); 
        else 
            par.c = round(par.c);
        end

        startupcl('vendor','amd','type', 'cpu');
        wl_filename = getWLfilename(par);
        if (~exist(wl_filename,'file'))
            A_mat = getAMat(par,angle_sensor,t);
            wl_filename = invertWL(A_mat,par);   
        end   
    else
        error(['Invalid Reconstruction selected: ' par.image_select ]);
    end
end

%% reconstruct
if (datainfo.is3D),
    R = zeros(par.n,par.n,par.nz,size(selMat,1));
else
    R = zeros(par.n,par.n,size(selMat,1));
end
ts = zeros(size(selMat,1),1);
coreNum = feature( 'numCores' ) ;
% progress bar
if (par.progress),
    wbar = waitbar(0,'Estimated Time Left: Unknown','Name','Reconstruction','CreateCancelBtn',...
            'setappdata(gcbf,''canceling'',1)');
end

for jj = 1:size(selMat,1)
    id = selMat(jj);
    tic;
    
    if (isnan(id)), continue; end;
    
    if logical(par.progress) && ~isempty(logical(getappdata(wbar,'canceling')))
        close(wbar);
        delete(wbar);
        error('User cancelled the reconstruction');
    end


    
    
    
    if par.laserCorrection,
        corrfac = datainfo.ScanFrames(id).LaserEnergy;
    else
        corrfac = 1;
    end

    % Reconstruction (lsqr or backprojection)    
    if strcmp(par.image_select,'direct')
        
        if (par.c < 1000)
    %         T = datainfo.AverageTemperature;
            T = datainfo.ScanFrames(id).Temperature;
            c = round(1.402385 * 1e3 + 5.038813 * T - 5.799136 * 1e-2 * T^2 + 3.287156 * 1e-4 * T^3 - 1.398845 * 1e-6 * T^4 + 2.787860 * 1e-9 * T^5 + par.c); 
        else 
            c = round(par.c);
        end
        
        %         fprintf('Backprojection: Image %i of %i (Frame %i)\n',jj,size(selMat,1),id);    
        if par.useGPU,
            if datainfo.is3D,
                LimitsX = [0,0];
                LimitsY = [0,0];
                LimitsZ = [0,0];
                axis = [0,0,1];
                theta = 0;
                [R(:,:,:,jj), fxy, fyz, fzx] = DeconvInterpRecon3D_cl( uint16(sigMat(:,:,jj)*fac), corrfac, ...
                    limits, [par.n,par.nz], r_sensor, c, fs, par.timeres, 0, ...
                    axis, theta, LimitsX, LimitsY, LimitsZ );
                R(:,:,:,jj) = R(:,:,:,jj) ./ fac;
            else
                R(:,:,jj) = DeconvInterpRecon2D_cl( uint16(sigMat(:,:,jj)*fac), corrfac, limits, ...
                    par.n, single(r_sensor), c, fs, par.timeres, 0 ) ./ fac;
            end
        else
            R(:,:,jj) = backproject( sigMat(:,:,jj), par.n, r_sensor(:, 1), r_sensor(:, 2), r_sensor(:, 3), c, 1, t', fs, par.roi, coreNum ) ./ corrfac;
        end
    elseif (strcmp(par.image_select,'model_lin'))   
%         fprintf('Model Based: Image %i of %i (Frame %i), %i iterations\n',jj,size(selMat,1),id,par.iter);    
        [recon, flag] = lsqr(A_mat, ...
            reshape(sigMat(:,:,jj),size(sigMat,1)*size(sigMat,2),1),...
            1e-6, par.iter);
        R(:,:,jj) = -reshape(recon,par.n,par.n)./corrfac;
        clear recon;
    end
    
    % time estimation
    if (par.progress),
        perimg = toc;
        est = round(perimg*(size(selMat,1)-jj)); est_unit = 's';
        if (est > 120) est = round(est / 60); est_unit = 'min'; end;    
        wbar = waitbar(jj/size(selMat,1),wbar,sprintf( 'Estimated Time Left: %i%s', est, est_unit )) ;
    end
    
    % Meta information
    wls(jj) = datainfo.ScanFrames(id).Wavelength;
    zpos(jj) = datainfo.ScanFrames(id).ZPos;
    ts(jj) = datainfo.ScanFrames(id).RelTime;
end
if (par.progress), close(wbar);delete(wbar); end

if (strcmp(par.image_select,'wavelet'))   
    fprintf('Wavelet Reconstruction: Batch processing %i images...\n',size(selMat,1));    
    [Lo_D,Hi_D] = wfilters(par.wl_name);
    SetWaveletFilters_cl(Lo_D, Hi_D);

    ok = loadWLModel_cl(wl_filename);
    sigMat = reshape(sigMat,size(sigMat,1)*size(sigMat,2),size(sigMat,3));

    tic
    R = ReconWLcl(sigMat, numel(t),par.proj,par.depth_proj,par.n);
    recont = toc;
    fprintf('  Execution time: %.1fs (%.3fs per image)\n',recont,recont/size(sigMat,2));
    
    cleanupcl;
end   

if (par.mirror),
    if (islogical(par.mirror)),
        R = R(par.n:-1:1,par.n:-1:1,:,:);
    else
        mi = double(par.mirror);
        if mod(mi,2) == 0,
            mi = mi - 2;
            R = R(par.n:-1:1,:,:,:);
        end
        if (double(par.mirror) == 1),
            R = R(:,par.n:-1:1,:,:);
        end
    end            
end

if datainfo.is3D,
    R = reshape(R,[par.n par.n par.nz svec]);
else
    R = reshape(R,[par.n par.n svec]);
end
ts = reshape(ts,svec);
wls = unique(wls);
zpos = unique(zpos);
sigMat = reshape(sigMat,[size(sigMat,1) size(sigMat,2) svec ]);

if (par.save == 2)
    savefile = [datainfo.FolderName '\' datainfo.FriendlyName ...
        '_' par.image_select...
        '_roi' num2str(par.roi*1e3,'%.1f')...
        '_n' num2str(par.n)...
        '_c' num2str(par.c)...
        '_proj' num2str(par.proj)...
        '_hp' num2str(par.filter_f(1)*1e-3,'%.0f') 'khz'...
        '.mat'];
    fprintf('Saving Recon to %s\n',savefile);
    save(savefile,'-v7.3','R','ts','wls','zpos','datainfo','par');
end
