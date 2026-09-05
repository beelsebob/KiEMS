%
% Tutorials / CRLH_Extraction
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2011-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Simulation Parameters
%% ---------------------
%% Define physical constants, working unit (micrometres), and the geometric
%% dimensions of the CRLH unit cell and microstrip feed lines.  The feed
%% length must be long enough for the microstrip mode to settle before
%% the de-embedding reference plane used in post-processing.
physical_constants;
unit = 1e-6; % specify everything in um

feed_length = 30000;

substrate_thickness = [1524 101 254];
substrate_epsr = [3.48 3.48 3.48];

CRLH.LL = 14e3;     %CRLH totel (line) length
CRLH.LW = 4e3;      %CRLH unit cell width (without the stubs)
CRLH.GLB = 1950;    %CRLH gap width bottom layer
CRLH.GLT = 4700;    %CRLH gap width top layer
CRLH.SL = 7800;     %CRLH stub length (bottom layer, both sides)
CRLH.SW = 1000;     %CRLH stub width  (bottom layer, both sides)
CRLH.VR = 250;      %CRLH via hole radius (stub -> ground)
CRLH.TopSig = sum(substrate_thickness);  %top layer height
CRLH.BottomSig = CRLH.TopSig - substrate_thickness(end);  %bottom layer height

% frequency range of interest
f_start = 0.8e9;
f_stop  = 6e9;

%% FDTD Parameters and Excitation
%% ------------------------------
%% A Gaussian pulse centred at the band mid-point covers the full 0.8-6 GHz
%% range in a single run.  PML absorbers terminate the feed direction and
%% the open top; MUR conditions damp the lateral faces; the PEC boundary
%% on the bottom acts as the ground plane.
FDTD = InitFDTD();
FDTD = SetGaussExcite( FDTD, (f_start+f_stop)/2, (f_stop-f_start)/2 );
BC   = {'PML_8' 'PML_8' 'MUR' 'MUR' 'PEC' 'PML_8'};
FDTD = SetBoundaryCond( FDTD, BC );

%% Mesh Initialization and CRLH Unit Cell
%% --------------------------------------
%% Seed coarse anchor points, then delegate fine metal detail to CreateCRLH,
%% which adds the top- and bottom-layer conductors, stubs, and via holes
%% together with the mesh lines they require.  SmoothMesh fills the gaps
%% so that cell sizes grow at no more than a 1.5x ratio per step.
CSX = InitCSX();
resolution = c0/(f_stop*sqrt(max(substrate_epsr)))/unit /30; % resolution of lambda/30

mesh.x = [-feed_length-CRLH.LL/2 0 feed_length+CRLH.LL/2];
mesh.y = [-30000 0 30000];
substratelines = cumsum(substrate_thickness);
mesh.z = [0 cumsum(substrate_thickness) linspace(substratelines(end-1),substratelines(end),4) 20000];

% create the CRLH unit cell (will define additional fixed mesh lines)
[CSX mesh] = CreateCRLH(CSX, mesh, CRLH, resolution/4);

% Smooth the given mesh
mesh = SmoothMesh(mesh, resolution, 1.5, 'algorithm',[1 3]);
CSX = DefineRectGrid( CSX, unit, mesh );

%% Substrate Layers
%% ----------------
%% Add each dielectric layer of the PCB stack as a separate material and
%% fill the full simulation domain in x and y.  Splitting the stack allows
%% each layer to carry its own permittivity, even though all three share
%% epsr = 3.48 in this example.
substratelines = [0 substratelines];
for n=1:numel(substrate_thickness)
    CSX = AddMaterial( CSX, ['substrate' int2str(n)] );
    CSX = SetMaterialProperty( CSX, ['substrate' int2str(n)], 'Epsilon', substrate_epsr(n) );
    start = [mesh.x(1),   mesh.y(1),   substratelines(n)];
    stop  = [mesh.x(end), mesh.y(end), substratelines(n+1)];
    CSX = AddBox( CSX, ['substrate' int2str(n)], 0, start, stop );
end

%% Microstrip Feed Ports
%% ---------------------
%% Attach one excited MSL port at the left feed end and one passive port at
%% the right to sample the transmitted wave.  MeasPlaneShift places the
%% voltage/current integration plane at the midpoint of the feed, and
%% FeedShift moves the excitation gap away from the simulation boundary.
CSX = AddMetal( CSX, 'PEC' );
portstart = [ mesh.x(1) , -CRLH.LW/2, substratelines(end)];
portstop  = [ -CRLH.LL/2,  CRLH.LW/2, 0];
[CSX,port{1}] = AddMSLPort( CSX, 999, 1, 'PEC', portstart, portstop, 0, [0 0 -1], 'ExcitePort', true, 'FeedShift', 10*resolution(1), 'MeasPlaneShift',  feed_length/2);

portstart = [ mesh.x(end) , -CRLH.LW/2, substratelines(end)];
portstop  = [ +CRLH.LL/2,   CRLH.LW/2, 0];
[CSX,port{2}] = AddMSLPort( CSX, 999, 2, 'PEC', portstart, portstop, 0, [0 0 -1], 'MeasPlaneShift',  feed_length/2 );

%% Write and Run the Simulation
%% ----------------------------
%% Serialize the complete structure and solver settings to an XML file, then
%% optionally inspect the geometry in AppCSXCAD before starting the solver.
%% Viewing the geometry first is a quick sanity-check that catches structural
%% errors before committing simulation time.
Sim_Path = 'tmp';
Sim_CSX = 'CRLH.xml';

CleanupSimPath(Sim_Path);

WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );
CSXGeomPlot( [Sim_Path '/' Sim_CSX] );
RunOpenEMS( Sim_Path, Sim_CSX );

%% S-Parameter Post-Processing
%% ---------------------------
%% Transform the time-domain port signals to the frequency domain and shift
%% the reference plane to the unit cell boundaries using calcPort.  Plotting
%% S11 and S21 gives an immediate check of return loss and insertion loss
%% before proceeding to the equivalent circuit extraction.
close all
f = linspace( f_start, f_stop, 1601 );
port = calcPort( port, Sim_Path, f, 'RefPlaneShift', feed_length);

s11 = port{1}.uf.ref./ port{1}.uf.inc;
s21 = port{2}.uf.ref./ port{1}.uf.inc;

plot(f/1e9,20*log10(abs(s11)),'k-','LineWidth',2);
hold on;
grid on;
plot(f/1e9,20*log10(abs(s21)),'r--','LineWidth',2);
l = legend('S_{11}','S_{21}','Location','Best');
set(l,'FontSize',12);
ylabel('S-Parameter (dB)','FontSize',12);
xlabel('frequency (GHz) \rightarrow','FontSize',12);
ylim([-40 2]);

%% CRLH Lumped Parameter Extraction
%% --------------------------------
%% Convert the two-port S-parameters to ABCD form and derive the series
%% impedance Z and shunt admittance Y of the unit cell.  The zero-crossings
%% of Im(Z) and Im(Y) locate the series resonance fse and shunt resonance
%% fsh, from which the four lumped elements LR, CL, CR, and LL follow.
A = ((1+s11).*(1-s11) + s21.*s21)./(2*s21);
C = ((1-s11).*(1-s11) - s21.*s21)./(2*s21) ./ port{2}.ZL;

Y = C;
Z = 2*(A-1)./C;

iZ = imag(Z);
iY = imag(Y);

fse = interp1(iZ,f,0);
fsh = interp1(iY,f,0);

df = f(2)-f(1);
fse_idx = find(f>fse,1);
fsh_idx = find(f>fsh,1);

LR = 0.5*(iZ(fse_idx)-iZ(fse_idx-1))./(2*pi*df);
CL = 1/(2*pi*fse)^2/LR;

CR = 0.5*(iY(fsh_idx)-iY(fsh_idx-1))./(2*pi*df);
LL = 1/(2*pi*fsh)^2/CR;

disp([' Series tank: CL = ' num2str(CL*1e12,3) 'pF;  LR = ' num2str(LR*1e9,3) 'nH -> f_se = ' num2str(fse*1e-9,3) 'GHz ']);
disp([' Shunt  tank: CR = ' num2str(CR*1e12,3) 'pF;  LL = ' num2str(LL*1e9,3) 'nH -> f_sh = ' num2str(fsh*1e-9,3) 'GHz ']);

%% Analytical Dispersion Relation
%% ------------------------------
%% Compute the Bloch-Floquet wave-number for an infinite periodic CRLH array
%% using the extracted lumped parameters LR, CL, CR, and LL.  This
%% analytical curve cross-checks the simulated dispersion and confirms that
%% a single simulated cell is representative of the periodic lattice.
w = 2*pi*f;
wse = 2*pi*fse;
wsh = 2*pi*fsh;
beta_calc = real(acos(1-(w.^2-wse^2).*(w.^2-wsh^2)./(2*w.^2/CR/LR)));

%% Dispersion Diagram
%% ------------------
%% Plot the simulated phase-constant beta derived from the S21 phase, the
%% analytical Bloch-wave curve, and the beta of the feed MSL for reference.
%% The backward-wave region at low frequencies confirms the left-handed
%% character of the CRLH unit cell.
figure
beta = -angle(s21)/CRLH.LL/unit;
plot(abs(beta)*CRLH.LL*unit/pi,f*1e-9,'k-','LineWidth',2)
grid on;
hold on;
plot(beta_calc/pi,f*1e-9,'c--','LineWidth',2)
plot(real(port{2}.beta)*CRLH.LL*unit/pi,f*1e-9,'g-','LineWidth',2)
ylim([1 6])
xlabel('|\beta| p / \pi \rightarrow','FontSize',12)
ylabel('frequency (GHz) \rightarrow','FontSize',12)
l = legend('\beta_{CRLH, 1 cell}','\beta_{CRLH, \infty cells}','\beta_{MSL}','Location','East');
set(l,'FontSize',12);
