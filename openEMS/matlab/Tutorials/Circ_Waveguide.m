%
% Tutorials / Circ_Waveguide
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2010-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Simulation Parameters
%% ---------------------
%% Define the waveguide dimensions and the frequency range of interest.
%% The radius ``rad`` sets the TE11 cut-off frequency (~251 MHz for 350 mm);
%% the chosen frequency span (300–500 MHz) therefore straddles the onset of
%% propagation and captures strongly dispersive behaviour.
physical_constants;
unit = 1e-3; %drawing unit in mm

% waveguide dimensions
length = 2000;
rad = 350;     %waveguide radius in mm

% frequency range of interest
f_start =  300e6;
f_stop  =  500e6;

mesh_res = [10 2*pi/49.999 10]; %targeted mesh resolution

%% FDTD Parameters and Excitation
%% -------------------------------
%% Configure the FDTD solver for cylindrical coordinates (``CoordSystem=1``)
%% and drive it with a Gaussian pulse centred in the band.  ``EndCriteria``
%% of 1e-4 stops the time-stepping once the remaining energy falls below
%% that fraction of the peak, keeping runtime short while ensuring the
%% impulse has decayed completely.  PML layers on both z-faces absorb
%% outgoing energy without spurious reflections.
FDTD = InitFDTD('EndCriteria',1e-4,'CoordSystem',1);
FDTD = SetGaussExcite(FDTD,0.5*(f_start+f_stop),0.5*(f_stop-f_start));

% boundary conditions
BC = [0 0 0 0 3 3]; %pml in pos. and neg. z-direction
FDTD = SetBoundaryCond(FDTD,BC);

%% Cylindrical Mesh Setup
%% ----------------------
%% A cylindrical mesh (r, azimuth, z) is the natural coordinate system for
%% this geometry: it avoids staircase errors on the curved conducting wall
%% and keeps cell counts manageable.  ``SmoothMeshLines`` distributes lines
%% evenly from the axis to the wall in r, over a full 2pi in azimuth, and
%% along the waveguide length in z.
CSX = InitCSX('CoordSystem',1); % init a cylindrical mesh
mesh.r = SmoothMeshLines([0 rad], mesh_res(1)); %mesh in radial direction
mesh.a = SmoothMeshLines([0 2*pi], mesh_res(2)); % mesh in aziumthal dir.
mesh.z = SmoothMeshLines([0 length], mesh_res(3));
CSX = DefineRectGrid(CSX, unit,mesh);

%% Waveguide Port Definition
%% -------------------------
%% Two TE11 mode ports bookend the waveguide: port 1 (excitation flag = 1)
%% injects the dominant circular-waveguide mode; port 2 at the far end acts
%% as a passive detector.  Placing each port several cells inward from the
%% PML boundary ensures the mode is fully formed before reaching the
%% absorber and that the port plane samples only the travelling wave.
start=[mesh.r(1)   mesh.a(1)   mesh.z(8)];
stop =[mesh.r(end) mesh.a(end) mesh.z(15)];
[CSX, port{1}] = AddCircWaveGuidePort( CSX, 0, 1, start, stop, rad*unit, 'TE11', 0, 1);

start=[mesh.r(1)   mesh.a(1)   mesh.z(end-13)];
stop =[mesh.r(end) mesh.a(end) mesh.z(end-14)];
[CSX, port{2}] = AddCircWaveGuidePort( CSX, 0, 2, start, stop, rad*unit, 'TE11');

%% Field Dump Configuration
%% ------------------------
%% Register a volumetric electric-field dump in HDF5 format (``FileType=1``)
%% spanning the entire simulation domain.  ``SubSampling`` of 4 in every
%% direction reduces the file size by a factor of 64 while still capturing
%% the spatial field structure at a resolution sufficient for visualisation
%% in ParaView or AppCSXCAD.
CSX = AddDump(CSX,'Et','FileType',1,'SubSampling','4,4,4');
start = [mesh.r(1)   mesh.a(1)   mesh.z(1)];
stop  = [mesh.r(end) mesh.a(end) mesh.z(end)];
CSX = AddBox(CSX,'Et',0 , start,stop);

%% Write XML and Run Simulation
%% ----------------------------
%% Serialise the complete simulation setup to an openEMS XML file and hand
%% it to the solver.  ``CleanupSimPath`` removes any previous run so stale
%% field dumps do not contaminate post-processing results.
Sim_Path = 'tmp';
Sim_CSX = 'circ_wg.xml';

CleanupSimPath(Sim_Path);

WriteOpenEMS([Sim_Path '/' Sim_CSX],FDTD,CSX);

RunOpenEMS(Sim_Path, Sim_CSX)

%% Post-Processing: Port Calculation
%% ----------------------------------
%% ``calcPort`` reads the time-domain probe signals, transforms them to the
%% frequency domain, and decomposes incident and reflected wave amplitudes
%% at each port.  S-parameters follow directly from the voltage wave ratios;
%% the complex wave impedance ``ZL`` is the ratio of total voltage to total
%% current and reveals the dispersive character of the TE11 mode near cut-off.
freq = linspace(f_start,f_stop,201);
port = calcPort( port, Sim_Path, freq);

s11 = port{1}.uf.ref./ port{1}.uf.inc;
s21 = port{2}.uf.ref./ port{1}.uf.inc;
ZL = port{1}.uf.tot./port{1}.if.tot;


%% S-Parameter Plot
%% ----------------
%% Plot S11 and S21 in dB across the frequency band.  Near cut-off S11
%% rises sharply as the mode cannot propagate; well above cut-off S21
%% should approach 0 dB (lossless transmission) and S11 should drop,
%% confirming that the waveguide is matched to the TE11 mode ports.
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

%% Waveguide Impedance Comparison
%% --------------------------------
%% Overlay the numerically extracted wave impedance (real and imaginary
%% parts of ``ZL``) against the analytic TE11 value stored in
%% ``port{1}.ZL``.  Close agreement between the two validates both the
%% mode excitation and the port normalisation; the strong frequency
%% dependence near cut-off is the hallmark of dispersive waveguide
%% propagation.
figure
plot(freq*1e-6,real(ZL),'Linewidth',2);
hold on;
grid on;
plot(freq*1e-6,imag(ZL),'r--','Linewidth',2);
plot(freq*1e-6,port{1}.ZL,'g-.','Linewidth',2);
ylabel('ZL (\Omega)','FontSize',12);
xlabel('frequency (MHz) \rightarrow','FontSize',12);
xlim([freq(1) freq(end)]*1e-6);
l = legend('\Re(Z_L)','\Im(Z_L)','Z_L analytic','Location','Best');
set(l,'FontSize',12);
