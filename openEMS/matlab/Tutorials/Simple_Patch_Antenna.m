%% Simple Patch Antenna Tutorial
%% -----------------------------
%% This tutorial simulates a microstrip patch antenna on a low-loss dielectric
%% substrate, covering the full workflow from geometry setup to S-parameter
%% extraction and far-field pattern analysis. It introduces the key openEMS
%% building blocks — CSXCAD geometry, lumped port excitation, automatic meshing,
%% and the near-field-to-far-field transformation — in a single self-contained
%% example.
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
%% --------------------
%% Define the physical dimensions and material properties of the patch,
%% substrate, and ground plane. The patch ``width`` controls the resonant
%% frequency — a narrower patch resonates higher — while the substrate
%% permittivity ``epsR`` and thickness together set the effective wavelength
%% inside the dielectric. The ``SimBox`` must be large enough that the
%% absorbing boundaries sit well away from the antenna near-field region.
physical_constants;
unit = 1e-3; % all length in mm

% patch width in x-direction
patch.width  = 32; % resonant length
% patch length in y-direction
patch.length = 40;

%substrate setup
substrate.epsR   = 3.38;
substrate.kappa  = 1e-3 * 2*pi*2.45e9 * EPS0*substrate.epsR;
substrate.width  = 60;
substrate.length = 60;
substrate.thickness = 1.524;
substrate.cells = 4;

%setup feeding
feed.pos = -6; %feeding position in x-direction
feed.R = 50;     %feed resistance

% size of the simulation box
SimBox = [200 200 150];

%% Setup FDTD Parameter & Excitation Function
%% ------------------------------------------
%% Configure the broadband Gaussian pulse and the first-order Mur absorbing
%% boundary conditions. The centre frequency ``f0`` and 20 dB bandwidth ``fc``
%% should bracket the expected patch resonance so that the full S-parameter
%% response is captured in a single simulation run. Mur boundaries are chosen
%% here because the antenna sits well inside the box; switch to PML if you
%% need stronger absorption for a more compact simulation domain.
f0 = 2e9; % center frequency
fc = 1e9; % 20 dB corner frequency
FDTD = InitFDTD( 'NrTs', 30000 );
FDTD = SetGaussExcite( FDTD, f0, fc );
BC = {'MUR' 'MUR' 'MUR' 'MUR' 'MUR' 'MUR'}; % boundary conditions
FDTD = SetBoundaryCond( FDTD, BC );

%% Setup CSXCAD Geometry & Mesh
%% ----------------------------
%% Build the complete antenna structure — patch metal, dielectric substrate,
%% ground plane, lumped feed port, and the NF2FF integration surface — inside
%% a single CSXCAD container. The mesh is generated with ``DetectEdges`` and
%% ``SmoothMesh``: patch edges are resolved at lambda/50 to capture the patch
%% current distribution accurately, while the surrounding free-space region
%% uses the coarser lambda/20 spacing to keep the total cell count manageable.
CSX = InitCSX();

%initialize the mesh with the "air-box" dimensions
mesh.x = [-SimBox(1)/2 SimBox(1)/2];
mesh.y = [-SimBox(2)/2 SimBox(2)/2];
mesh.z = [-SimBox(3)/3 SimBox(3)*2/3];

% Create Patch
CSX = AddMetal( CSX, 'patch' ); % create a perfect electric conductor (PEC)
start = [-patch.width/2 -patch.length/2 substrate.thickness];
stop  = [ patch.width/2  patch.length/2 substrate.thickness];
CSX = AddBox(CSX,'patch',10,start,stop); % add a box-primitive to the metal property 'patch'

% Create Substrate
CSX = AddMaterial( CSX, 'substrate' );
CSX = SetMaterialProperty( CSX, 'substrate', 'Epsilon', substrate.epsR, 'Kappa', substrate.kappa );
start = [-substrate.width/2 -substrate.length/2 0];
stop  = [ substrate.width/2  substrate.length/2 substrate.thickness];
CSX = AddBox( CSX, 'substrate', 0, start, stop );

% add extra cells to discretize the substrate thickness
mesh.z = [linspace(0,substrate.thickness,substrate.cells+1) mesh.z];

% Create Ground same size as substrate
CSX = AddMetal( CSX, 'gnd' ); % create a perfect electric conductor (PEC)
start(3)=0;
stop(3) =0;
CSX = AddBox(CSX,'gnd',10,start,stop);

% Apply the Excitation & Resist as a Current Source
start = [feed.pos 0 0];
stop  = [feed.pos 0 substrate.thickness];
[CSX port] = AddLumpedPort(CSX, 5 ,1 ,feed.R, start, stop, [0 0 1], true);

% Finalize the Mesh
% detect all edges except of the patch
mesh = DetectEdges(CSX, mesh,'ExcludeProperty','patch');
% detect and set a special 2D metal edge mesh for the patch
mesh = DetectEdges(CSX, mesh,'SetProperty','patch','2D_Metal_Edge_Res', c0/(f0+fc)/unit/50);
% generate a smooth mesh with max. cell size: lambda_min / 20
mesh = SmoothMesh(mesh, c0/(f0+fc)/unit/20);
CSX = DefineRectGrid(CSX, unit, mesh);

CSX = AddDump(CSX,'Hf', 'DumpType', 11, 'Frequency',[2.4e9]);
CSX = AddBox(CSX,'Hf',10,[-substrate.width -substrate.length -10*substrate.thickness],[substrate.width +substrate.length 10*substrate.thickness]); %assign box

% add a nf2ff calc box; size is 3 cells away from MUR boundary condition
start = [mesh.x(4)     mesh.y(4)     mesh.z(4)];
stop  = [mesh.x(end-3) mesh.y(end-3) mesh.z(end-3)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop);

%% Prepare and Run Simulation
%% --------------------------
%% Write the geometry and solver settings to an XML file, optionally preview
%% the structure in AppCSXCAD, then launch the openEMS solver. Inspecting the
%% geometry plot before running is strongly recommended: it lets you verify
%% patch, substrate, and port placement immediately, without waiting for the
%% solver to finish.
Sim_Path = 'tmp_Patch_Ant';
Sim_CSX = 'patch_ant.xml';

% create an empty working directory
CleanupSimPath(Sim_Path);

% write openEMS compatible xml-file
WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );

% show the structure
CSXGeomPlot( [Sim_Path '/' Sim_CSX] );

% run openEMS
RunOpenEMS( Sim_Path, Sim_CSX);

%% Postprocessing & Plots
%% ----------------------
%% Read back the time-domain port voltages and currents recorded during the
%% simulation and transform them to the frequency domain. ``calcPort`` computes
%% the incident and reflected wave amplitudes at each frequency point; these
%% are the basis for the impedance, S11, and radiation-efficiency calculations
%% that follow.
freq = linspace( max([1e9,f0-fc]), f0+fc, 501 );
port = calcPort(port, Sim_Path, freq);

%% Smith Chart Port Reflection
%% ---------------------------
%% Plot the reflection coefficient on a Smith chart and as an S11 magnitude
%% curve to characterise the antenna input match. A deep null in ``|S11|`` at the
%% design frequency confirms resonance; the -10 dB bandwidth indicates the
%% usable frequency range over which the antenna is well matched to the
%% 50 Ohm feed.
plotRefl(port, 'threshold', -10)
title( 'reflection coefficient' );

% plot feed point impedance
Zin = port.uf.tot ./ port.if.tot;
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
s11 = port.uf.ref ./ port.uf.inc;
figure
plot( freq/1e6, 20*log10(abs(s11)), 'k-', 'Linewidth', 2 );
grid on
title( 'reflection coefficient S_{11}' );
xlabel( 'frequency f / MHz' );
ylabel( 'reflection coefficient |S_{11}|' );

drawnow

%% NFFF Plots
%% ----------
%% Invoke the near-field-to-far-field transformation to obtain the radiation
%% pattern at the resonant frequency identified from the S11 minimum. Sampling
%% at phi = 0 and 90 degrees reveals the two principal-plane cuts; the
%% subsequent full-sphere calculation yields maximum directivity and radiation
%% efficiency, showing how effectively the antenna converts accepted power into
%% useful far-field radiation.
%find resonance frequency from s11
f_res_ind = find(s11==min(s11));
f_res = freq(f_res_ind);

% calculate the far field at phi=0 degrees and at phi=90 degrees
disp( 'calculating far field at phi=[0 90] deg...' );

nf2ff = CalcNF2FF(nf2ff, Sim_Path, f_res, [-180:2:180]*pi/180, [0 90]*pi/180);

% display power and directivity
disp( ['radiated power: Prad = ' num2str(nf2ff.Prad) ' Watt']);
disp( ['directivity: Dmax = ' num2str(nf2ff.Dmax) ' (' num2str(10*log10(nf2ff.Dmax)) ' dBi)'] );
disp( ['efficiency: nu_rad = ' num2str(100*nf2ff.Prad./port.P_inc(f_res_ind)) ' %']);

% normalized directivity as polar plot
figure
polarFF(nf2ff,'xaxis','theta','param',[1 2],'normalize',1)

% log-scale directivity plot
figure
plotFFdB(nf2ff,'xaxis','theta','param',[1 2])
% conventional plot approach
% plot( nf2ff.theta*180/pi, 20*log10(nf2ff.E_norm{1}/max(nf2ff.E_norm{1}(:)))+10*log10(nf2ff.Dmax));

drawnow

% Show 3D pattern
disp( 'calculating 3D far field pattern and dumping to vtk (use Paraview to visualize)...' );
thetaRange = (0:2:180);
phiRange = (0:2:360) - 180;
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f_res, thetaRange*pi/180, phiRange*pi/180,'Verbose',1,'Outfile','3D_Pattern.h5');

figure
plotFF3D(nf2ff,'logscale',-20);


E_far_normalized = nf2ff.E_norm{1} / max(nf2ff.E_norm{1}(:)) * nf2ff.Dmax;
DumpFF2VTK([Sim_Path '/3D_Pattern.vtk'],E_far_normalized,thetaRange,phiRange,'scale',1e-3);
