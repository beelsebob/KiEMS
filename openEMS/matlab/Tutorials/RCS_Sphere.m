%
% Tutorials / Radar Cross Section of a Metal Sphere
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2012-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Setup the Simulation
%% --------------------
%% Define physical constants, spatial units, sphere geometry, incident angle, and simulation box dimensions.
physical_constants;
unit = 1e-3; % all length in mm

sphere.rad = 200;

inc_angle = 0 /180*pi; %incident angle (to x-axis) in rad

% size of the simulation box
SimBox = 1000;
PW_Box = 750;

%% FDTD Parameters and Excitation
%% -------------------------------
%% Set the frequency sweep for a Gaussian pulse excitation and apply absorbing (PML) boundary conditions on all six faces.
f_start =  50e6; % start frequency
f_stop = 1000e6; % stop  frequency
f0 = 500e6;

FDTD = InitFDTD( );
FDTD = SetGaussExcite( FDTD, 0.5*(f_start+f_stop), 0.5*(f_stop-f_start) );
BC = [1 1 1 1 1 1]*3;  % set boundary conditions
FDTD = SetBoundaryCond( FDTD, BC );

%% CSXCAD Geometry and Mesh
%% -------------------------
%% Initialize the geometry container and build a symmetric Cartesian mesh with cell size lambda/20 at the highest frequency.
max_res = c0 / f_stop / unit / 20; % cell size: lambda/20
CSX = InitCSX();

%create mesh
smooth_mesh = SmoothMeshLines([0 SimBox/2], max_res);
mesh.x = unique([-smooth_mesh smooth_mesh]);
mesh.y = mesh.x;
mesh.z = mesh.x;

%% Create the Metal Sphere
%% -----------------------
%% Add a perfect electric conductor (PEC) sphere centered at the origin; the analytical RCS of this sphere is known and can be used to validate the simulation.
CSX = AddMetal( CSX, 'sphere' ); % create a perfect electric conductor (PEC)
CSX = AddSphere(CSX,'sphere',10,[0 0 0],sphere.rad);

%% Plane Wave Excitation
%% ---------------------
%% Use the total-field/scattered-field (TFSF) technique to inject a z-polarized plane wave; the TFSF box separates the total-field region (containing the sphere) from the pure scattered-field region outside.
k_dir = [cos(inc_angle) sin(inc_angle) 0]; % plane wave direction
E_dir = [0 0 1]; % plane wave polarization --> E_z

CSX = AddPlaneWaveExcite(CSX, 'plane_wave', k_dir, E_dir, f0);
start = [-PW_Box/2 -PW_Box/2 -PW_Box/2];
stop  = -start;
CSX = AddBox(CSX, 'plane_wave', 0, start, stop);

%% Electric Field Dump
%% -------------------
%% Record the time-domain electric field in the xy-plane for visualization in ParaView.
CSX = AddDump(CSX, 'Et');
start = [mesh.x(1)   mesh.y(1)   0];
stop  = [mesh.x(end) mesh.y(end) 0];
CSX = AddBox(CSX, 'Et', 0, start, stop);

%% Near-Field to Far-Field Box
%% ---------------------------
%% Place an NF2FF surface around the computational domain to enable far-field RCS computation after the simulation; PML lines are added outside this surface.
start = [mesh.x(1)     mesh.y(1)     mesh.z(1)];
stop  = [mesh.x(end) mesh.y(end) mesh.z(end)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop);

% add 8 lines in all direction as pml spacing
mesh = AddPML(mesh,8);

CSX = DefineRectGrid( CSX, unit, mesh );

%% Prepare Simulation Folder
%% -------------------------
%% Set the output directory and XML filename, then clean any previous results.
Sim_Path = 'tmp_Sphere_RCS';
Sim_CSX = 'Sphere_RCS.xml';

CleanupSimPath(Sim_Path);

%% Write XML File
%% --------------
%% Serialize the FDTD setup and geometry to the openEMS XML input file.
WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );

%% Show the Structure
%% ------------------
%% Launch the geometry viewer to verify the mesh and sphere placement before running.
CSXGeomPlot( [Sim_Path '/' Sim_CSX] );

%% Run openEMS
%% -----------
%% Execute the FDTD simulation; this typically takes about one minute.
RunOpenEMS( Sim_Path, Sim_CSX);

%% Post-Processing: Incident Power
%% --------------------------------
%% Read the incident E-field at ``f0`` from the TFSF surface and compute the incident power needed to normalize the RCS.
disp('Use Paraview to display the elctric fields dumped by openEMS');

EF = ReadUI( 'et', Sim_Path, f0 ); % time domain/freq domain voltage
Pin = 0.5*norm(E_dir)^2/Z0 .* abs(EF.FD{1}.val).^2;

%% Bistatic RCS at Single Frequency
%% ---------------------------------
%% Compute the full bistatic RCS pattern in the xy-plane at ``f0`` using the NF2FF transformation and display it as a polar plot.
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f0, pi/2, [-180:2:180]*pi/180, 'Mode',1);
RCS = 4*pi./Pin(1).*nf2ff.P_rad{1}(:);
polar(nf2ff.phi,RCS);
xlabel('x -->');
ylabel('y -->');
hold on
grid on

drawnow

%% Back-Scatter over Frequency Range
%% ----------------------------------
%% Sweep the full frequency band to compute the monostatic (back-scatter) RCS as a function of frequency.
freq = linspace(f_start,f_stop,100);
EF = ReadUI( 'et', Sim_Path, freq ); % time domain/freq domain voltage
Pin = 0.5*norm(E_dir)^2/Z0 .* abs(EF.FD{1}.val).^2;

nf2ff = CalcNF2FF(nf2ff, Sim_Path, freq, pi/2, pi+inc_angle, 'Mode',1);
for fn=1:numel(freq)
    back_scat(fn) = 4*pi./Pin(fn).*nf2ff.P_rad{fn}(1);
end

%% Plot RCS vs Frequency
%% ---------------------
%% Display the back-scatter RCS in m² over the simulated frequency range.
figure
plot(freq/1e6,back_scat,'Linewidth',2);
grid on;
xlabel('frequency (MHz) \rightarrow');
ylabel('RCS (m^2) \rightarrow');
title('radar cross section');

%% Normalized Radar Cross Section
%% -------------------------------
%% Normalize the back-scatter RCS to the sphere's geometric cross section (pi*a^2) and plot against the electrical size (radius/wavelength) to compare with the Mie series solution.
figure
lambda = c0./freq;
semilogy(sphere.rad*unit./lambda,back_scat/(pi*sphere.rad*unit*sphere.rad*unit),'Linewidth',2);
ylim([10^-2 10^1])
grid on;
xlabel('sphere radius / wavelength \rightarrow');
ylabel('RCS / (\pi a^2) \rightarrow');
title('normalized radar cross section');
