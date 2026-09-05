.. _octave_tutorial_uwb_radar:

UWB Radar — Delay and Fidelity
================================

Simulate a simple UWB monopole antenna across IEEE 802.15.4 channels and
compute delay and fidelity as figures of merit for time-domain pulse integrity.
**Simulation time: ~3 min.**

**This tutorial covers:**

* Channel-configurable Gaussian excitation matched to IEEE 802.15.4 UWB bandwidths (channels 1–5, 7)
* Advanced meshing: fine resolution near antenna structures, coarser resolution in free space, graded via ``SmoothMeshLines``
* :func:`DelayFidelity` for time-domain pulse characterization
* Polar plots of delay (mm) and fidelity (%) vs. angle
* Comparison across multiple UWB channels

Octave/Matlab Script
--------------------

.. include:: ./__RadarUWBTutorial.txt

Images
------

.. figure:: images/UWB_Antenna_Geometry.png
    :width: 80%
    :alt: UWB antenna geometry

    UWB monopole antenna geometry (AppCSXCAD)

.. figure:: images/RadarUWB_S11.svg
    :width: 80%
    :alt: S11 magnitude and phase vs. frequency for UWB channel 4

    Reflection coefficient \|S\ :sub:`11`\| and phase for UWB channel 4

.. figure:: images/RadarUWB_gain.svg
    :width: 80%
    :alt: Gain polar plot for UWB channel 4

    Gain (dBi) polar plot for UWB channel 4

.. figure:: images/RadarUWB_delay.svg
    :width: 80%
    :alt: Delay polar plot for UWB channel 4

    Delay (mm) polar plot for UWB channel 4

.. figure:: images/RadarUWB_fidelity.svg
    :width: 80%
    :alt: Fidelity polar plot for UWB channel 4

    Fidelity (%) polar plot for UWB channel 4
