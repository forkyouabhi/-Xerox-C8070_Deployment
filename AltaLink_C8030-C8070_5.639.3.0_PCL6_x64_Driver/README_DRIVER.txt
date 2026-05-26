DRIVER FOLDER PLACEHOLDER
=========================

Place the contents of your Xerox AltaLink C8070 PCL6 driver here.

Expected structure:
  AltaLink_C8030-C8070_5.639.3.0_PCL6_x64_Driver\
    └── x3ASKYX.inf
    └── (all other driver files)

The driver package is not included in this repository for size reasons.
Download from: https://www.support.xerox.com
Search: AltaLink C8070 PCL6 Windows 64-bit driver v5.639.3.0

Also place these files in the root of XeroxC8070_Package\ before packaging:
  - SecurePrint.dat          (exported from a manually configured reference printer)
  - SecurePrintDevMode.bin   (exported HKLM DevMode binary from reference printer)

See CHANGELOG.md for export instructions.
