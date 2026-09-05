%
% Tutorials / helical antenna
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2012-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

post_proc_only = 1;

close all

%% Simulation Parameters
%% ---------------------
%% Define the waveguide dimensions and operating frequency. The helix
%% radius sets the TE10 cut-off frequency of the axial mode; keeping the
%% pitch near lambda/4 and the circumference near one wavelength maximises
%% broadside gain. Expected gain for 10 turns is approximately 16 dBi.
physical_constants;
unit = 1e-3; % all length in mm

f0 = 2.4e9; % center frequency, frequency of interest!
lambda0 = round(c0/f0/unit); % wavelength in mm
fc = 0.5e9; % 20 dB corner frequency

Helix.radius = 20; % --> diameter is ~ lambda/pi
Helix.turns = 10;  % --> expected gain is G ~ 4 * 10 = 40 (16dBi)
Helix.pitch = 30;  % --> pitch is ~ lambda/4
Helix.mesh_res = 3;

gnd.radius = lambda0/2;

% feeding
feed.heigth = 3;
feed.R = 120;    %feed impedance

% size of the simulation box
SimBox = [1 1 1.5]*2*lambda0;

%% FDTD Solver Configuration
%% --------------------------
%% Initialise the time-domain solver and choose the excitation signal. A
%% Gaussian pulse centred on f0 with bandwidth fc excites all frequencies
%% of interest in a single simulation run. PML absorbing boundaries on
%% five sides and a Mur ABC on the remaining faces truncate the open space.
FDTD = InitFDTD( );
FDTD = SetGaussExcite( FDTD, f0, fc );
BC = {'MUR' 'MUR' 'MUR' 'MUR' 'MUR' 'PML_8'}; % boundary conditions
FDTD = SetBoundaryCond( FDTD, BC );

%% Mesh Setup
%% ----------
%% Build the FDTD Yee mesh to resolve both the fine helix wire geometry and
%% the surrounding air-box. Dense lines (Helix.mesh_res) capture the wire
%% curvature; SmoothMeshLines then expands the grid smoothly outward at a
%% 1.4 grading ratio to keep the cell count manageable.
max_res = floor(c0 / (f0+fc) / unit / 20); % cell size: lambda/20
CSX = InitCSX();

% create helix mesh
mesh.x = SmoothMeshLines([-Helix.radius 0 Helix.radius],Helix.mesh_res);
% add the air-box
mesh.x = [mesh.x -SimBox(1)/2-gnd.radius  SimBox(1)/2+gnd.radius];
% create a smooth mesh between specified fixed mesh lines
mesh.x = SmoothMeshLines( mesh.x, max_res, 1.4);

% copy x-mesh to y-direction
mesh.y = mesh.x;

% create helix mesh in z-direction
mesh.z = SmoothMeshLines([0 feed.heigth Helix.turns*Helix.pitch+feed.heigth],Helix.mesh_res);
% add the air-box
mesh.z = unique([mesh.z -SimBox(3)/2 max(mesh.z)+SimBox(3)/2 ]);
% create a smooth mesh between specified fixed mesh lines
mesh.z = SmoothMeshLines( mesh.z, max_res, 1.4 );

CSX = DefineRectGrid( CSX, unit, mesh );

%% Helix Wire Geometry
%% -------------------
%% Construct the helical conductor as a polyline curve primitive. The coil
%% coordinates are computed analytically and stacked turn-by-turn along z,
%% starting above the feed gap. Using a wire primitive rather than a box
%% allows the helix to be modelled with sub-cell accuracy on a Cartesian mesh.
CSX = AddMetal( CSX, 'helix' ); % create a perfect electric conductor (PEC)

ang = linspace(0,2*pi,21);
coil_x = Helix.radius*cos(ang);
coil_y = Helix.radius*sin(ang);
coil_z = ang/2/pi*Helix.pitch;

helix.x=[];
helix.y=[];
helix.z=[];
zpos = feed.heigth;
for n=0:Helix.turns-1
    helix.x = [helix.x coil_x];
    helix.y = [helix.y coil_y];
    helix.z = [helix.z coil_z+zpos];
    zpos = zpos + Helix.pitch;
end
clear p
p(1,:) = helix.x;
p(2,:) = helix.y;
p(3,:) = helix.z;
CSX = AddCurve(CSX, 'helix', 0, p);

%% Circular Ground Plane
%% ---------------------
%% Add a circular PEC ground plane at z=0 using cylindrical coordinates.
%% The ground plane reflects backward radiation and serves as the reference
%% conductor for the coaxial feed; a radius of lambda/2 is the practical
%% minimum that suppresses back-lobe degradation in axial-mode operation.
CSX = AddMetal( CSX, 'gnd' ); % create a perfect electric conductor (PEC)
% add a box using cylindrical coordinates
start = [0          0    0];
stop  = [gnd.radius 2*pi 0];
CSX = AddBox(CSX,'gnd',10,start,stop,'CoordSystem',1);

%% Lumped Feed Port
%% ----------------
%% Insert a lumped port between the helix base and the ground plane to
%% model the coaxial feed. The 120 Ohm source resistance approximates the
%% natural impedance of an axial-mode helix and is used to compute the
%% incident and reflected wave quantities needed for S11.
start = [Helix.radius 0 0];
stop  = [Helix.radius 0 feed.heigth];
[CSX port] = AddLumpedPort(CSX, 5 ,1 ,feed.R, start, stop, [0 0 1], true);

%% Near-Field to Far-Field Box
%% ---------------------------
%% Place the NF2FF integration surface just inside the absorbing boundary
%% walls. The OptResolution argument subsamples the recorded fields to
%% lambda/15, which drastically reduces memory and runtime while retaining
%% sufficient angular resolution in the far-field transform.
start = [mesh.x(11)      mesh.y(11)     mesh.z(11)];
stop  = [mesh.x(end-10) mesh.y(end-10) mesh.z(end-10)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop, 'OptResolution', lambda0/15);

%% Simulation Folder Setup
%% -----------------------
%% Specify the output directory and XML filename before writing any files.
%% Keeping all simulation artefacts in a dedicated subdirectory makes it
%% easy to clean up or archive a run without touching the script itself.
Sim_Path = 'tmp_Helical_Ant';
Sim_CSX = 'Helix_Ant.xml';

if (post_proc_only==0)
    CleanupSimPath(Sim_Path);

    %% Export Simulation to XML
    %% ------------------------
    %% Serialise the complete FDTD and CSXCAD description to the openEMS
    %% XML format. This file is the sole input to the solver and can be
    %% inspected or re-run independently of Octave.
    WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );

    %% Geometry Preview
    %% ----------------
    %% Open the AppCSXCAD viewer to confirm that the helix, ground plane,
    %% feed port, and NF2FF box are positioned correctly before committing
    %% to a potentially long solver run.
    CSXGeomPlot( [Sim_Path '/' Sim_CSX] );

    %% Run Simulation
    %% --------------
    %% Launch the openEMS FDTD solver on the exported XML. The solver runs
    %% until the time-domain energy has decayed sufficiently, ensuring
    %% accurate frequency-domain results across the full pulse bandwidth.
    RunOpenEMS( Sim_Path, Sim_CSX);
end

%% Port Post-Processing and S-Parameters
%% --------------------------------------
%% Compute frequency-domain port quantities from the time-domain field
%% recordings. The feed point impedance Zin and reflection coefficient S11
%% reveal how well the helix is matched to the 120 Ohm source across the
%% band of interest.
freq = linspace( f0-fc, f0+fc, 501 );
port = calcPort(port, Sim_Path, freq);

Zin = port.uf.tot ./ port.if.tot;
s11 = port.uf.ref ./ port.uf.inc;

% plot feed point impedance
figure
plot( freq/1e6, real(Zin), 'k-', 'Linewidth', 2 );
hold on
grid on
plot( freq/1e6, imag(Zin), 'r--', 'Linewidth', 2 );
title( 'feed point impedance' );
xlabel( 'frequency f / MHz' );
ylabel( 'impedance Z_{in} / Ohm' );
legend( 'real', 'imag' );

% plot reflection coefficient S11
figure
plot( freq/1e6, 20*log10(abs(s11)), 'k-', 'Linewidth', 2 );
grid on
xlim( [(f0-fc)/1e6, (f0+fc)/1e6])
ylim( [-30, 0])
title( 'reflection coefficient S_{11}' );
xlabel( 'frequency f / MHz' );
ylabel( 'reflection coefficient |S_{11}|' );

drawnow

%% Far-Field Pattern Calculation
%% ------------------------------
%% Invoke the NF2FF transformation to obtain the full 3-D radiation pattern
%% at the resonance frequency. The half-power beamwidth is extracted from
%% the phi=0 cut to characterise the axial-mode beam quality.
%find resonance frequncy from s11
f_res = f0;

% get accepted antenna power at frequency f0
P_in_0 = interp1(freq, port.P_acc, f0);

% calculate the far field at phi=0 degrees and at phi=90 degrees
thetaRange = unique([0:0.5:90 90:180]);
phiRange = (0:2:360) - 180;
disp( 'calculating the 3D far field...' );

nf2ff = CalcNF2FF(nf2ff, Sim_Path, f_res, thetaRange*pi/180, phiRange*pi/180,'Mode',0,'Outfile','3D_Pattern.h5','Verbose',1);

theta_HPBW = interp1(nf2ff.E_norm{1}(:,1)/max(nf2ff.E_norm{1}(:,1)),thetaRange,1/sqrt(2))*2;

% display power and directivity
disp( ['radiated power: Prad = ' num2str(nf2ff.Prad) ' Watt']);
disp( ['directivity: Dmax = ' num2str(nf2ff.Dmax) ' (' num2str(10*log10(nf2ff.Dmax)) ' dBi)'] );
disp( ['efficiency: nu_rad = ' num2str(100*nf2ff.Prad./P_in_0) ' %']);
disp( ['theta_HPBW = ' num2str(theta_HPBW) ' °']);


%% Directivity Decomposition
%% -------------------------
%% Separate the total directivity into right-hand and left-hand circular
%% polarisation components. An ideal axial-mode helix radiates pure CPRH;
%% the ratio of CPRH to CPLH power is a figure of merit for polarisation purity.
directivity = nf2ff.P_rad{1}/nf2ff.Prad*4*pi;
directivity_CPRH = abs(nf2ff.E_cprh{1}).^2./max(nf2ff.E_norm{1}(:)).^2*nf2ff.Dmax;
directivity_CPLH = abs(nf2ff.E_cplh{1}).^2./max(nf2ff.E_norm{1}(:)).^2*nf2ff.Dmax;

%% Radiation Pattern Plot
%% ----------------------
%% Plot the elevation cut of directivity (total, CPRH, and CPLH) in dBi
%% versus theta. The narrow main lobe and high CPRH-to-CPLH ratio confirm
%% axial-mode operation with good circular polarisation at broadside (theta=0).
figure
plot(thetaRange, 10*log10(directivity(:,1)'),'k-','LineWidth',2);
hold on
grid on
xlabel('theta (deg)');
ylabel('directivity (dBi)');
plot(thetaRange, 10*log10(directivity_CPRH(:,1)'),'g--','LineWidth',2);
plot(thetaRange, 10*log10(directivity_CPLH(:,1)'),'r-.','LineWidth',2);
legend('norm','CPRH','CPLH');

%% Export Far-Field to VTK
%% -----------------------
%% Write the 3-D directivity patterns to VTK files so they can be visualised
%% in ParaView or any VTK-compatible viewer. Scaling by 1e-3 converts the
%% pattern radius from mm to metres for consistent display alongside other
%% simulation geometry.
DumpFF2VTK([Sim_Path '/3D_Pattern.vtk'],directivity,thetaRange,phiRange,'scale',1e-3);
DumpFF2VTK([Sim_Path '/3D_Pattern_CPRH.vtk'],directivity_CPRH,thetaRange,phiRange,'scale',1e-3);
DumpFF2VTK([Sim_Path '/3D_Pattern_CPLH.vtk'],directivity_CPLH,thetaRange,phiRange,'scale',1e-3);
