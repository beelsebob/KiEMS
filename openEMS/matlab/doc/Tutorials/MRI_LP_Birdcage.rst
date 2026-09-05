.. _octave_tutorial_mri_lp_birdcage:

MRI Linear Polarized Birdcage Coil
====================================

Simulate a linear-polarized birdcage coil for MRI at 297 MHz (7 T), tune
the resonance with distributed capacitors, and evaluate B1 field homogeneity.

**This tutorial covers:**

* Birdcage coil geometry with multiple rungs and end rings
* Distributed lumped capacitors for resonance tuning
* B1 field homogeneity assessment across the coil bore

Octave/Matlab Script
--------------------

.. include:: ./__MRI_LP_Birdcage.txt

Images
------

.. figure:: images/MRI_LP_BirdCage_CSX.png
    :width: 80%
    :alt: 3D geometry of the birdcage coil

    3D view of the linear-polarized birdcage coil (AppCSXCAD)

.. figure:: images/MRI_LP_BirdCage_B1.png
    :width: 80%
    :alt: B1 field distribution

    B1 field distribution inside the coil bore

.. figure:: images/MRI_LP_BirdCage_SAR.png
    :width: 80%
    :alt: SAR distribution

    SAR distribution in the phantom

.. figure:: images/MRI_LP_BirdCage_3D_SAR.png
    :width: 80%
    :alt: 3D SAR distribution

    3D SAR distribution

Body Model
----------

This tutorial requires the **Ella** voxel body model from the IT'IS Virtual
Family dataset (``Ella_26y_V2_1mm``). The dataset is free for academic and
non-commercial use but requires registration and a license agreement from the
IT'IS Foundation (https://itis.swiss/virtual-population/).

Once downloaded, the raw files are converted to an openEMS HDF5 DiscMaterial
file by ``Convert_VF_DiscMaterial`` (run once, result is cached).

Literature
----------

* A. Christ et al., "The Virtual Family — Development of surface-based
  anatomical models of two adults and two children for dosimetric simulations,"
  *Phys. Med. Biol.*, vol. 55, 2010.
