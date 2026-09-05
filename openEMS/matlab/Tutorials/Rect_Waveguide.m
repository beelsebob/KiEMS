%
% Tutorials / Rect Waveguide
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2010-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Setup the Simulation
%% ---------------------
%% Load physical constants, set the drawing unit to µm, and define the WR-42
%% waveguide dimensions, operating frequency range centred at 24 GHz, dominant
%% TE10 mode, and a target mesh resolution of 30 cells per free-space wavelength.
physical_constants;
unit = 1e-6; %drawing unit in um

% waveguide dimensions
% WR42
a = 10700;   %waveguide width
b = 4300;    %waveguide height
length = 50000;

% frequency range of interest
f_start = 20e9;
f_0     = 24e9;
f_stop  = 26e9;
lambda0 = c0/f_0/unit;

%waveguide TE-mode definition
TE_mode = 'TE10';

%targeted mesh resolution
mesh_res = lambda0./[30 30 30];

%% FDTD Parameters and Excitation
%% --------------------------------
%% Initialize the FDTD time-stepper with a Gaussian pulse covering the full
%% analysis band. PML terminations on both z-faces absorb outgoing waves;
%% PEC boundaries on x and y faces form the conducting waveguide walls.
FDTD = InitFDTD('NrTS',1e4, 'OverSampling', 5);
FDTD = SetGaussExcite(FDTD,0.5*(f_start+f_stop),0.5*(f_stop-f_start));

% boundary conditions
BC = [0 0 0 0 3 3]; %pml in pos. and neg. z-direction
FDTD = SetBoundaryCond(FDTD,BC);

%% CSXCAD Mesh
%% ------------
%% Create the rectilinear mesh using ``SmoothMeshLines`` to distribute mesh
%% lines at the target density across all three dimensions.
CSX = InitCSX();
mesh.x = SmoothMeshLines([0 a], mesh_res(1));
mesh.y = SmoothMeshLines([0 b], mesh_res(2));
mesh.z = SmoothMeshLines([0 length], mesh_res(3));
CSX = DefineRectGrid(CSX, unit,mesh);

%% Waveguide Ports
%% ----------------
%% Place two rectangular waveguide ports inside the PML boundaries. Port 1 is
%% active (driven with unit amplitude); port 2 is passive. Both use the analytic
%% TE10 mode profile for excitation and field sampling.
start=[mesh.x(1)   mesh.y(1)   mesh.z(11)];
stop =[mesh.x(end) mesh.y(end) mesh.z(15)];
[CSX, port{1}] = AddRectWaveGuidePort( CSX, 0, 1, start, stop, 'z', a*unit, b*unit, TE_mode, 1);

start=[mesh.x(1)   mesh.y(1)   mesh.z(end-13)];
stop =[mesh.x(end) mesh.y(end) mesh.z(end-14)];
[CSX, port{2}] = AddRectWaveGuidePort( CSX, 0, 2, start, stop, 'z', a*unit, b*unit, TE_mode);

%% Field Dump
%% -----------
%% Register a time-domain E-field dump over the entire simulation volume.
%% Sub-sampling by 2 in each direction keeps the HDF5 output file size manageable.
CSX = AddDump(CSX,'Et','FileType',1,'SubSampling','2,2,2');
start = [mesh.x(1)   mesh.y(1)   mesh.z(1)];
stop  = [mesh.x(end) mesh.y(end) mesh.z(end)];
CSX = AddBox(CSX,'Et',0 , start,stop);

%% Write and Run
%% --------------
%% Serialize the simulation model to XML and launch the openEMS solver.
%% ``CleanupSimPath`` removes any stale results from a previous run.
Sim_Path = 'tmp_mod';
Sim_CSX = 'rect_wg.xml';

CleanupSimPath(Sim_Path);

WriteOpenEMS([Sim_Path '/' Sim_CSX],FDTD,CSX);

RunOpenEMS(Sim_Path, Sim_CSX)

%% Post-processing
%% ----------------
%% Compute frequency-domain port quantities with ``calcPort``, then extract
%% S-parameters and the numerical wave impedance from the port voltage and
%% current spectra.
freq = linspace(f_start,f_stop,201);
port = calcPort(port, Sim_Path, freq);

s11 = port{1}.uf.ref./ port{1}.uf.inc;
s21 = port{2}.uf.ref./ port{1}.uf.inc;
ZL = port{1}.uf.tot./port{1}.if.tot;
ZL_a = port{1}.ZL; % analytic waveguide impedance

%% S-Parameter Plot
%% -----------------
%% Plot S11 and S21 in dB across the analysis band. For an ideal lossless
%% waveguide S21 should be near 0 dB and S11 well below −30 dB.
figure
plot(freq*1e-6,20*log10(abs(s11)),'k-','Linewidth',2);
xlim([freq(1) freq(end)]*1e-6);
grid on;
hold on;
plot(freq*1e-6,20*log10(abs(s21)),'r--','Linewidth',2);
l = legend('S_{11}','S_{21}','Location','Best');
set(l,'FontSize',12);
ylabel('S-Parameter (dB)','FontSize',12);
xlabel('frequency (MHz) \rightarrow','FontSize',12);

%% Wave Impedance Comparison
%% --------------------------
%% Compare the numerically extracted wave impedance (real and imaginary parts)
%% against the analytic TE10 impedance to validate the port calibration.
figure
plot(freq*1e-6,real(ZL),'Linewidth',2);
hold on;
grid on;
plot(freq*1e-6,imag(ZL),'r--','Linewidth',2);
plot(freq*1e-6,ZL_a,'g-.','Linewidth',2);
ylabel('ZL (\Omega)','FontSize',12);
xlabel('frequency (MHz) \rightarrow','FontSize',12);
xlim([freq(1) freq(end)]*1e-6);
l = legend('\Re(Z_L)','\Im(Z_L)','Z_L analytic','Location','Best');
set(l,'FontSize',12);

%% Field Animation
%% ----------------
%% Animate the stored E-field time snapshots at a mid-plane cross-section to
%% visualise wave propagation through the waveguide.
figure
dump_file = [Sim_Path '/Et.h5'];
PlotArgs.slice = {a/2*unit b/2*unit 0};
PlotArgs.pauseTime=0.01;
PlotArgs.component=0;
PlotArgs.Limit = 'auto';
PlotHDF5FieldData(dump_file, PlotArgs)
