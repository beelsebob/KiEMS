% Rect_WG_W_WG_Ports.m
%
% Rectangular waveguide (WR-42) with generic waveguide ports using HDF5
% mode files. The TE10 field distribution is computed analytically and
% written to HDF5 files on the fly via h5writemode.
%
% This is the Matlab/Octave counterpart of the Python test
% Rect_WG_W_WG_Ports.py. Results should be indistinguishable from the
% analytic-function version in Rect_Waveguide.m.
%
% Assertions:
%   S11 < -20 dB across the passband
%   S21 > -1  dB across the passband
%
% (c) 2026 Thorsten Liebig <thorsten.liebig@gmx.de>

clc; clear; close all;

physical_constants;

% -------------------------------------------------------------------------
% Geometry  (drawing unit: 1 µm, WR-42 standard dimensions)
unit   = 1e-6;
a      = 10700;     % waveguide width  (µm)
b      = 4300;      % waveguide height (µm)
length = 50000;     % waveguide length (µm)

f_start = 20e9;
f_0     = 24e9;
f_stop  = 26e9;

lambda0  = c0 / f_0 / unit;   % free-space wavelength at f_0 (drawing units)
mesh_res = lambda0 / 30;

kc = pi / (a * unit);          % TE10 cutoff wavenumber (rad/m)

% -------------------------------------------------------------------------
% Paths
Sim_Path  = fullfile(tempdir, 'Rect_WG_HDF5');
Mode_Path = fullfile(tempdir, 'Rect_WG_HDF5_modes');
if ~exist(Mode_Path, 'dir'), mkdir(Mode_Path); end

E_file = fullfile(Mode_Path, 'TE10_E.h5');
H_file = fullfile(Mode_Path, 'TE10_H.h5');

% -------------------------------------------------------------------------
% Generate HDF5 mode files (TE10)
%   E: Vx = 0,              Vy = -sin(pi*x/a) / a
%   H: Vx = sin(pi*x/a)/a,  Vy = 0
%
% Grid runs from x=0..a and y=0..b; local_origin='corner' aligns the port
% box corner with (0,0) so mode file and simulation coordinates match.
N      = 60;
x_mode = linspace(0, a, N);
y_mode = linspace(0, b, max(round(N * b / a), 2));
nx     = numel(x_mode);
ny     = numel(y_mode);
[XX, ~] = ndgrid(x_mode, y_mode);   % XX(i,j) = x_mode(i), size (nx,ny)

Vx_E = zeros(nx, ny);
Vy_E = -sin(pi * XX / a) / a;
h5writemode(E_file, x_mode, y_mode, Vx_E, Vy_E);

Vx_H = sin(pi * XX / a) / a;
Vy_H = zeros(nx, ny);
h5writemode(H_file, x_mode, y_mode, Vx_H, Vy_H);

% -------------------------------------------------------------------------
% FDTD setup
FDTD = InitFDTD('NrTS', 1e6);
FDTD = SetGaussExcite(FDTD, 0.5*(f_start+f_stop), 0.5*(f_stop-f_start));
FDTD = SetBoundaryCond(FDTD, {'PEC','PEC','PEC','PEC','PML_8','PML_8'});

CSX = InitCSX();

mesh.x = [0, a];
mesh.y = [0, b];
mesh.z = [0, length];

% Pin mesh lines at both port faces before smoothing
z_p1_start = 10 * mesh_res;
z_p1_stop  = 15 * mesh_res;
z_p2_start = length - 10 * mesh_res;
z_p2_stop  = length - 15 * mesh_res;
mesh.z = unique([mesh.z, z_p1_start, z_p1_stop, z_p2_start, z_p2_stop]);

mesh.x = SmoothMeshLines(mesh.x, mesh_res, 1.4);
mesh.y = SmoothMeshLines(mesh.y, mesh_res, 1.4);
mesh.z = SmoothMeshLines(mesh.z, mesh_res, 1.4);

CSX = DefineRectGrid(CSX, unit, mesh);

% -------------------------------------------------------------------------
% Waveguide ports  (local_origin='corner' aligns mode file x=0,y=0 with
% the lower-left corner of the port box)
[CSX, port{1}] = AddWaveGuidePort(CSX, 0, 1, ...
    [0, 0, z_p1_start], [a, b, z_p1_stop], 'z', {}, {}, kc, 1, ...
    'E_WG_file', E_file, 'H_WG_file', H_file, 'local_origin', 'corner');

[CSX, port{2}] = AddWaveGuidePort(CSX, 0, 2, ...
    [0, 0, z_p2_start], [a, b, z_p2_stop], 'z', {}, {}, kc, 0, ...
    'E_WG_file', E_file, 'H_WG_file', H_file, 'local_origin', 'corner');

% -------------------------------------------------------------------------
% Run
CleanupSimPath(Sim_Path);

WriteOpenEMS(fullfile(Sim_Path, 'rect_wg.xml'), FDTD, CSX);
RunOpenEMS(Sim_Path, 'rect_wg.xml');

% -------------------------------------------------------------------------
% Post-processing
freq = linspace(f_start, f_stop, 201);
k    = 2*pi*freq / c0;
Z_TE = k .* Z0 ./ sqrt(k.^2 - kc^2);   % TE10 wave impedance (frequency-dependent)
port = calcPort(port, Sim_Path, freq, 'RefImpedance', Z_TE);

S11 = port{1}.uf.ref ./ port{1}.uf.inc;
S21 = port{2}.uf.ref ./ port{1}.uf.inc;

S11_dB = 20 * log10(abs(S11));
S21_dB = 20 * log10(abs(S21));

fprintf('S11 max = %.1f dB\n', max(S11_dB));
fprintf('S21 min = %.1f dB\n', min(S21_dB));

assert(max(S11_dB) < -20, sprintf('S11 too high: %.1f dB', max(S11_dB)));
assert(min(S21_dB) > -1,  sprintf('S21 too low:  %.1f dB', min(S21_dB)));

disp('PASS');

figure;
plot(freq/1e9, [S11_dB(:), S21_dB(:)], 'linewidth', 2);
grid on;
xlabel('Frequency (GHz)');
ylabel('S-Parameters (dB)');
title('Rectangular Waveguide (WR-42) with HDF5 Mode Ports');
legend('S11', 'S21');
