.. _octave_tutorial_conical_horn:

Conical Horn Antenna
====================

Simulate a conical horn antenna fed by a circular waveguide, compute its
S-parameters and far-field radiation pattern, and evaluate aperture efficiency.

**This tutorial covers:**

* Conical horn geometry via ``AddRotPoly`` (rotational polygon) on a
  **Cartesian** grid — even though the horn is rotationally symmetric, openEMS
  uses a rectangular mesh throughout; the circular profile is approximated by
  the rotational polygon
* Circular waveguide port (``AddCircWaveGuidePort``, TE11 mode) with
  ``horn.radius`` set to the circular waveguide (feed) radius
* Simulation time: < 10 min; far-field calculations: ~1 hour
* Note: the z-mesh does not extend to ``-SimBox/2`` but starts at
  ``-horn.feed_length`` — the mesh only covers the actual structure

Octave/Matlab Script
--------------------

.. include:: ./__Conical_Horn_Antenna.txt

Images
------

.. figure:: images/Conical-horn-model.png
    :width: 80%
    :alt: Conical horn model

    Conical horn geometry with circular waveguide feed (AppCSXCAD)

.. figure:: images/Conical-horn-xsection.png
    :width: 80%
    :alt: Cross-section of the conical horn

    Cross-section showing the rotational polygon that defines the horn wall

.. figure:: images/Conical-horn-mesh.png
    :width: 80%
    :alt: Mesh in the x-z plane

    Cartesian mesh in the x-z plane — note the mesh starts at
    ``-horn.feed_length`` in z, not at the SimBox boundary

.. figure:: images/Conical-horn-gridding.png
    :width: 80%
    :alt: Detail of mesh gridding near the aperture

    Mesh detail near the aperture edge

.. figure:: images/Conical_Horn_Antenna_S11.png
    :width: 80%
    :alt: S11 over frequency

    Reflection coefficient S11 over frequency

.. figure:: images/Conical_Horn_Antenna_2D_RadPattern.png
    :width: 80%
    :alt: 2D polar farfield at 15 GHz

    2D polar far-field pattern at 15 GHz

.. figure:: images/Conical_Horn_Antenna_RadPattern.png
    :width: 80%
    :alt: 3D farfield radiation pattern

    3D far-field radiation pattern of the conical horn antenna
