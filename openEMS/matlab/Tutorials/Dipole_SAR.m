%
% Tutorials / Dipole SAR + Power budget
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2013-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Switches and Options
%% --------------------
%% The ``postprocessing_only`` flag lets you re-run the analysis after a
%% completed simulation without repeating the time-consuming FDTD solve.
%% Set it to 1 when you have existing result files and only want to
%% regenerate plots or change post-processing parameters.
postprocessing_only = 0;

%% Simulation Folder Setup
%% -----------------------
%% All simulation input and output files are written to a dedicated
%% subdirectory. Keeping the XML geometry file and the HDF5 result files
%% together in one folder makes it easy to run multiple parameter studies
%% side by side without file name conflicts.
Sim_Path = 'tmp_Dipole_SAR';
Sim_CSX = 'Dipole_SAR.xml';

%% Simulation Parameters
%% ---------------------
%% Load physical constants (speed of light, permittivity of free space)
%% and set the global length unit to millimetres. The lumped port feed
%% resistance ``feed.R`` should match the characteristic impedance of the
%% measurement system -- 50 Ohm is the standard RF reference impedance.
physical_constants;
unit = 1e-3; % all lengths in mm

feed.R = 50; % feed resistance

%% Human Head Phantom Definition
%% -----------------------------
%% The phantom models a simplified human head as three concentric
%% ellipsoids: skin, skull bone, and brain, each with realistic
%% permittivity, conductivity, and mass density from tissue databases at
%% 1 GHz. The layered structure captures the dominant electromagnetic
%% shielding by the skull and the high water content of brain tissue
%% that drives SAR absorption.
phantom{1}.name='skin';
phantom{1}.epsR = 50;
phantom{1}.kappa = 0.65; % S/m
phantom{1}.density = 1100; % kg/m^3
phantom{1}.radius = [80 100 100]; % ellipsoide
phantom{1}.center = [100 0 0];

phantom{2}.name='headbone';
phantom{2}.epsR = 13;
phantom{2}.kappa = 0.1; % S/m
phantom{2}.density = 2000; % kg/m^3
phantom{2}.radius = [75 95 95]; % ellipsoide
phantom{2}.center = [100 0 0];

phantom{3}.name='brain';
phantom{3}.epsR = 60;
phantom{3}.kappa = 0.7; % S/m
phantom{3}.density = 1040; % kg/m^3
phantom{3}.radius = [65 85 85]; % ellipsoide
phantom{3}.center = [100 0 0];

%% FDTD Parameters and Excitation
%% -------------------------------
%% A Gaussian pulse band-limited to ``f_stop`` excites the structure over
%% a wide frequency range in a single simulation run. The dipole length
%% is set to a half-wavelength at the centre frequency for resonance; the
%% two mesh resolutions balance accuracy inside the lossy phantom (2.5 mm)
%% against efficiency in the surrounding air (lambda/20).
f0 = 1e9; % center frequency
lambda0 = c0/f0;

f_stop = 1.5e9; % 20 dB corner frequency
lambda_min = c0/f_stop;

mesh_res_air = lambda_min/20/unit;
mesh_res_phantom = 2.5;

dipole_length = 0.48*lambda0/unit;
disp(['Lambda-half dipole length: ' num2str(dipole_length) 'mm'])

%% FDTD Solver Configuration
%% -------------------------
%% ``CellConstantMaterial`` ensures each Yee cell uses a single
%% homogeneous material value, which is required for correct SAR
%% calculation inside curved phantom boundaries. PML-8 absorbing
%% boundaries surround the entire domain to simulate an antenna
%% radiating into unbounded free space.
FDTD = InitFDTD('CellConstantMaterial', 1); % make sure the material is constant per voxel
FDTD = SetGaussExcite( FDTD, 0, f_stop );
% apply PML-8 boundary conditions in all directions
BC = {'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8'};
FDTD = SetBoundaryCond( FDTD, BC );

%% CSXCAD Geometry Initialisation
%% --------------------------------
%% Initialise the CSXCAD geometry container that will hold all material
%% regions, the dipole metal, the lumped port, and the dump box
%% definitions. All subsequent calls populate this single structure,
%% which is later serialised to XML for the solver.
CSX = InitCSX();

%% Dipole Antenna Geometry
%% -----------------------
%% The dipole is modelled as a zero-thickness perfect electric conductor
%% (PEC) line along the z-axis, centred at the origin. The feed gap is
%% left open at z = 0 to be filled by the lumped port; initial mesh seed
%% lines at the dipole tips ensure adequate field resolution along the
%% wire.
CSX = AddMetal( CSX, 'Dipole' ); % create a perfect electric conductor (PEC)
CSX = AddBox(CSX, 'Dipole', 1, [0 0 -dipole_length/2], [0 0 dipole_length/2]);

% mesh lines for the dipole
mesh.x = 0;
mesh.y = 0;
mesh.z = [-dipole_length/2-[-1/3 2/3]*mesh_res_phantom dipole_length/2+[-1/3 2/3]*mesh_res_phantom];

%% Phantom Dielectric Layers
%% -------------------------
%% Each phantom layer is added as a scaled and translated ellipsoid with
%% its tissue-specific material properties. CSXCAD assigns overlapping
%% primitives by priority -- higher-priority inner layers (brain > bone
%% > skin) take precedence, automatically creating nested shell geometry
%% without manual Boolean operations.
for n=1:numel(phantom)
  CSX = AddMaterial( CSX, phantom{n}.name );
  CSX = SetMaterialProperty( CSX, phantom{n}.name, 'Epsilon', phantom{n}.epsR, 'Kappa', phantom{n}.kappa, 'Density', phantom{n}.density);
  CSX = AddSphere( CSX, phantom{n}.name, 10+n, [0 0 0], 1,'Transform',{'Scale',phantom{n}.radius, 'Translate', phantom{n}.center} );

  % mesh lines for the dielectrics
  mesh.x = [mesh.x phantom{n}.radius(1)*[-1 1]+phantom{n}.center(1) ];
  mesh.y = [mesh.y phantom{n}.radius(2)*[-1 1]+phantom{n}.center(2) ];
  mesh.z = [mesh.z phantom{n}.radius(3)*[-1 1]+phantom{n}.center(3) ];
end

%% Lumped Port Excitation
%% ----------------------
%% A lumped port placed at the dipole feed gap acts simultaneously as
%% the voltage source and the S-parameter reference plane. The port
%% impedance matches ``feed.R`` so that ``port.P_acc`` (accepted power)
%% correctly excludes reflected power from the SAR and power-budget
%% calculations.
[CSX port] = AddLumpedPort(CSX, 100, 1, feed.R, [-0.1 -0.1 -mesh_res_phantom/2], [0.1 0.1 +mesh_res_phantom/2], [0 0 1], true);

% mesh lines for the port
mesh.z = [mesh.z -mesh_res_phantom/2 +mesh_res_phantom/2];

%% Mesh Smoothing Over Dipole and Phantom
%% ---------------------------------------
%% ``SmoothMesh`` fills in the gaps between the manually placed seed
%% lines with a graded Cartesian mesh, keeping cell sizes at or below
%% the phantom resolution. A uniform fine mesh inside the phantom is
%% critical for accurate SAR averaging -- abrupt cell-size jumps would
%% introduce interpolation errors in the spatially-averaged SAR.
mesh = SmoothMesh(mesh, mesh_res_phantom);

%% Air-Box and Final Mesh Smoothing
%% ---------------------------------
%% Outer boundary lines define the computational domain large enough to
%% contain both the PML and the NF2FF box. A coarser maximum cell size
%% (lambda_min/20, growth ratio 1.2) smoothly transitions the dense
%% phantom mesh out to the PML, minimising reflections and reducing the
%% total cell count.
mesh.x = [mesh.x -200 250+100];
mesh.y = [mesh.y -250 250];
mesh.z = [mesh.z -250 250];

% smooth the final mesh (incl. air box)
mesh = SmoothMesh(mesh, mesh_res_air, 1.2);

%% SAR Dump Box Configuration
%% --------------------------
%% ``DumpType 29`` requests a frequency-domain power-loss density dump
%% in W/m^3, which the post-processing step converts to spatially-
%% averaged SAR in W/kg. The dump box is intentionally larger than the
%% phantom so that the full extent of tissue absorption is captured;
%% only voxels with non-zero conductivity and density contribute to the
%% averaged SAR.
start = [-30 -120 -120];
stop = [200  120  120];
CSX = AddDump( CSX, 'SAR', 'DumpType', 29, 'Frequency', f0,'FileType',1,'DumpMode',2);
CSX = AddBox( CSX, 'SAR', 0, start, stop);

%% Near-Field to Far-Field Box
%% ---------------------------
%% The NF2FF surface encloses the simulation domain just inside the PML
%% to capture all radiated fields. It is used here not only for the
%% antenna pattern but also for the power budget: the total radiated
%% power ``Prad`` plus absorbed power from the SAR dump should sum to
%% the accepted port power, providing a self-consistency check.
start = [mesh.x(1)   mesh.y(1)   mesh.z(1)];
stop  = [mesh.x(end) mesh.y(end) mesh.z(end)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop, 'OptResolution', lambda_min/15/unit);

%% PML Padding and Mesh Finalisation
%% -----------------------------------
%% Ten additional air cells are inserted between the NF2FF surface and
%% the PML absorber to keep the boundary away from near-field sources.
%% The mesh is then locked into CSXCAD via ``DefineRectGrid`` -- no
%% further geometry or mesh changes are possible after this call.
% add 10 equidistant cells (air)
% around the structure to keep the pml away from the nf2ff box
mesh = AddPML( mesh, 10 );

% Define the mesh
CSX = DefineRectGrid(CSX, unit, mesh);

%% Write Geometry and Run Simulation
%% -----------------------------------
%% When not in post-processing-only mode the XML geometry file is
%% written and the structure is previewed before the solver is invoked.
%% Inspecting the geometry plot at this stage is good practice -- it
%% catches meshing or placement errors before the potentially long FDTD
%% run begins.
if (postprocessing_only==0)
    CleanupSimPath(Sim_Path);

    % write openEMS compatible xml-file
    WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );

    % show the structure
    CSXGeomPlot( [Sim_Path '/' Sim_CSX] );

    % run openEMS
    RunOpenEMS( Sim_Path, Sim_CSX );
end


%% Port Post-Processing
%% --------------------
%% ``calcPort`` transforms the time-domain port signals to the frequency
%% domain and computes the accepted power spectrum. ``Pin_f0`` is the
%% accepted (incident minus reflected) power at the centre frequency;
%% all SAR and radiated-power quantities are normalised to this value to
%% give results per watt of accepted power.
freq = linspace(500e6, 1500e6, 501 );
port = calcPort(port, Sim_Path, freq);

s11 = port.uf.ref./port.uf.inc;
Zin = port.uf.tot./port.if.tot;

Pin_f0 = interp1(freq, port.P_acc, f0);

%% Feed Impedance and Reflection Plots
%% -------------------------------------
%% Plotting the complex input impedance alongside S11 gives complementary
%% views of the antenna match: the impedance chart shows the resonance
%% condition (Im(Zin) -> 0), while S11 in dB indicates how much power is
%% reflected. A half-wave dipole near a lossy phantom typically shows a
%% shifted resonance and broader S11 minimum compared to free space.
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
plot( freq/1e9, 20*log10(abs(s11)), 'k-', 'Linewidth', 2 );
grid on
title( 'reflection coefficient' );
xlabel( 'frequency f / MHz' );
ylabel( 'S_{11} (dB)' );

avg_mass = 1  % 1g averaging mass

SAR_fn = [Sim_Path '/SAR_' num2str(avg_mass) 'g.h5'] % calculated SAR output
CalcSAR([Sim_Path '/SAR.h5'], SAR_fn, 'mass', avg_mass, 'method', 'IEEE_62704')

%% SAR Data Import
%% ---------------
%% The 1 g-averaged SAR field is read back from the HDF5 file together
%% with the total absorbed power and the averaging mass. These three
%% quantities -- field distribution, total power, and mass -- are all
%% needed to cross-check the per-voxel SAR against the whole-body figure
%% reported in the power budget.
SAR_field = ReadHDF5Dump(SAR_fn);

SAR = SAR_field.FD.values{1};
ptotal = ReadHDF5Attribute(SAR_fn,'/FieldData/FD/f0','power');
mass = ReadHDF5Attribute(SAR_fn,'/','mass');

%% Far-Field Pattern Calculation
%% ------------------------------
%% The NF2FF transformation computes the full 3D radiation pattern over
%% a sphere of elevation and azimuth angles. The far-field result is
%% needed to extract the total radiated power ``Prad`` for the power
%% budget, and it confirms that the dipole pattern is disturbed by the
%% phantom as expected for a body-mounted antenna.
phi = 0:3:360;
theta = 0:3:180;

disp( 'calculating 3D far field pattern...' );
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f0, theta*pi/180, phi*pi/180, 'Outfile','3D_Pattern.h5');

%% Power Budget Summary
%% --------------------
%% The power budget cross-checks that absorbed power (from the SAR dump)
%% and radiated power (from the NF2FF) sum to approximately 100 % of the
%% accepted port power. A budget closure within a few percent confirms
%% that the mesh is fine enough and the NF2FF box is correctly placed;
%% large discrepancies point to mesh problems or PML over-absorption.
disp(['max SAR: ' num2str(max(SAR(:))/Pin_f0) ' W/kg normalized to 1 W accepted power']);
disp(['whole body SAR: ' num2str(ptotal/Pin_f0/mass) ' W/kg normalized to 1 W accepted power']);
disp(['accepted power: ' num2str(Pin_f0) ' W (100 %)']);
disp(['radiated power: ' num2str(nf2ff.Prad) ' W ( ' num2str(round(100*(nf2ff.Prad) / Pin_f0)) ' %)']);
disp(['absorbed power: ' num2str(ptotal) ' W ( ' num2str(round(100*(ptotal) / Pin_f0)) ' %)']);
disp(['power budget:   ' num2str(100*(nf2ff.Prad + ptotal) / Pin_f0) ' %']);

%% SAR Distribution on the XY Plane
%% ----------------------------------
%% The horizontal cross-section through the phantom (z = 0) shows the
%% lateral SAR gradient from the dipole feed point outward into the
%% tissues. Displaying on a logarithmic colour scale reveals the
%% several-orders-of-magnitude dynamic range between the high-SAR region
%% near the antenna and the interior of the skull.
[SAR_field SAR_mesh] = ReadHDF5Dump(SAR_fn,'Range',{[],[],0});
figure
[X Y] = ndgrid(SAR_mesh.lines{1},SAR_mesh.lines{2});
h = pcolor(X,Y,log10(SAR_field.FD.values{1}/abs(Pin_f0)));
title( ['logarithmic ' num2str(avg_mass) 'g-SAR on an xy-plane'] );
xlabel('x -->')
ylabel('y -->')
axis equal tight
set(h,'EdgeColor','none');

%% SAR Distribution on the XZ Plane
%% ----------------------------------
%% The vertical cross-section (y = 0) reveals how SAR varies along the
%% dipole axis and through the tissue layers. This view makes it easy to
%% see the depth of penetration into the brain and to verify that the
%% layered ellipsoid geometry is correctly resolved by the mesh.
[SAR_field SAR_mesh] = ReadHDF5Dump(SAR_fn,'Range',{[],0,[]});
figure
[X Z] = ndgrid(SAR_mesh.lines{1},SAR_mesh.lines{3});
h = pcolor(X,Z,log10(squeeze(SAR_field.FD.values{1}))/abs(Pin_f0));
title( ['logarithmic ' num2str(avg_mass) 'g-SAR on an xz-plane'] );
xlabel('x -->')
ylabel('z -->')
axis equal tight
set(h,'EdgeColor','none');

%% VTK Export for 3D Visualisation
%% --------------------------------
%% The full 3D SAR distribution is exported to a VTK file for volumetric
%% rendering in ParaView or similar tools. The ``weight`` parameter
%% normalises the field to 1 W of accepted input power, yielding a
%% result in W/kg per W that can be directly scaled to any desired
%% transmit power level.
disp(['Full 1g normalized SAR has been dumped to vtk file! Use Paraview to visualize']);
ConvertHDF5_VTK(SAR_fn,[Sim_Path '/SAR'],'weight',1/abs(Pin_f0),'FieldName','SAR_1g' );
