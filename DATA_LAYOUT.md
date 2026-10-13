# Data Layout Documentation

## Overview

This document describes the data organization for mouse brain CZI processing in the Petersen Lab at EPFL.

## Input Data Structure

### Base Location
```
/home/lmsmith/servers/data
```

### Directory Structure
```
servers/data/
├── LS001/                    # User folder (initials + 3-digit number)
│   ├── Anatomy/
│   │   └── LS001.czi        # Raw CZI file (named after brain ID)
│   ├── IOS/
│   ├── Recording/
│   ├── SLIMS/
│   └── Training/
├── LS010/
│   └── Anatomy/
│       └── LS010.czi
└── MS181/
    └── Anatomy/
        └── MS181.czi
```

### Naming Conventions

**User Folders:**
- Format: `<Initials><3-digit-number>`
- Examples: `LS001`, `LS010`, `LS132`, `MS181`
- Initials: First letter of first name + first letter of last name (e.g., Lana Smith → LS)

**Brain Data:**
- One `.czi` file per brain in the `Anatomy/` subfolder
- File named according to brain identifier
- Example: `MS181/Anatomy/MS181.czi`

### Access Methods

#### 1. GIO Mount (Slow)
```bash
# Via mounted NAS drive
/home/lmsmith/servers/data/MS181/Anatomy/MS181.czi
```

#### 2. SSH (Fast - Recommended for Pipeline)
```bash
# Via SSH - much faster transfer speed
lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-data/MS181/Anatomy/MS181.czi
```

**Usage in Pipeline:**
```bash
nextflow run main.nf -resume -profile slurm \
  --input lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-data/MS181/Anatomy/MS181.czi
```

### Access Permissions
- ✅ **Write access:** Can create new files
- ❌ **No modification access:** Once a file is written, it cannot be modified
- ⚠️ **Implication:** Output files must be written to a different location

---

## Output Data Structure

### Base Location
```
/home/lmsmith/servers/analysis
```

### Directory Structure
```
servers/analysis/
├── Anand_Karthik/
├── Anthony_Renard/
├── Axel_Bisi/
├── Carl_Petersen/
├── Jules_Lebert/
├── Lana_Smith/
│   ├── MS122/
│   │   ├── analysis/              # Directory
│   │   ├── ch0/                   # Channel 0 data
│   │   ├── ch1/                   # Channel 1 data
│   │   ├── fiji_intensity/        # Directory
│   │   ├── MS122.xml              # XML file
│   │   └── registration/          # Registration results
│   └── MS181/
│       ├── analysis/
│       ├── ch0/
│       ├── ch1/
│       ├── fiji_intensity/
│       ├── MS181.xml
│       └── registration/
├── Marianne_Nkosi/
├── Mauro_Pulin/
└── ...
```

### Naming Conventions

**User Output Folders:**
- Format: `<FirstName>_<LastName>`
- Examples: `Lana_Smith`, `Carl_Petersen`, `Mauro_Pulin`

**Brain Output Folders:**
- Named after brain identifier (matches input)
- Example: `Lana_Smith/MS122/`

**Output Contents:**
- `analysis/` - Analysis results
- `ch0/`, `ch1/`, etc. - Per-channel fused TIFF data (published by pipeline)
- `fiji_intensity/` - Fiji intensity measurements
- `<brain_id>.xml` - BigStitcher XML file
- `<brain_id>_unregistered.xml` - BigStitcher XML before stitching
- `<brain_id>_registered.xml` - BigStitcher XML after stitching
- `registration/` - Brain registration results from brainreg

### SSH Access

```bash
lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-analysis/<Full_Name>/<brain_id>/
```

This is configured as `output_base_path` in `nextflow.config` and used automatically when `--user_name` is provided.

---

## OME-Zarr Output (Optional)

### Base Location
```
/work/lsens/
```

### Directory Structure
```
/work/lsens/
├── Lana_Smith/
│   ├── MS122/
│   │   └── ch1.ome.zarr        # Multi-resolution OME-Zarr pyramid
│   └── MS181/
│       └── ch1.ome.zarr
├── Biop_User/
│   └── MS040/
│       └── ch1.ome.zarr
└── ...
```

### Details

- **Enabled by default** on the slurm profile; skip with `--skip_ome_zarr` (always skipped on the local profile)
- **Source:** Fused ch1 TIFF from BigStitcher
- **Format:** OME-Zarr with 6 resolution levels, chunk size `(1,1,256,256,256)`
- **Path:** `/work/lsens/<user_name>/<brain_id>/ch1.ome.zarr`
- **Access:** Local cluster path (no SSH needed), writable from compute nodes

---

## Pipeline Integration

### Usage

The pipeline uses `--brain_id` and `--user_name` to automatically construct input/output paths:

```bash
nextflow run main.nf -resume -profile slurm --brain_id MS181 --user_name Lana_Smith -with-trace
```

The pipeline constructs:
1. **Input:** `<ssh_host>:<input_base_path>/<brain_id>/Anatomy/<brain_id>.czi`
2. **Output:** `<ssh_host>:<output_base_path>/<user_name>/<brain_id>/`

### File Publishing

All outputs are published to the analysis tree (`output_base_path`):

**XML Files** (published to `<user_name>/<brain_id>/`):
- `<brain_id>_unregistered.xml` - Published after initial dataset creation
- `<brain_id>_registered.xml` - Published after stitching/registration

**Fused Channel TIFFs** (published to `<user_name>/<brain_id>/ch<N>/`):
- Each channel from BigStitcher fusion is published to its own subfolder
- Example: `Lana_Smith/MS181/ch0/`, `Lana_Smith/MS181/ch1/`

**OME-Zarr** (published to `/work/lsens/<user_name>/<brain_id>/`, on by default):
- `ch1.ome.zarr` - Multi-resolution pyramid of the fused ch1 channel
- Skipped when `--skip_ome_zarr` is passed

**Registration Results** (published to `<user_name>/<brain_id>/registration/`):
- Subdirectories named with parameter combinations, including the atlas used
- Format: `<brain_id>_atlas<value>_bending_energy_weight<value>_grid_spacing<value>_smoothing_sigma_floating<value>/`
- `atlas` isn't swept (one value per run, from `params.brainreg.atlas` in `nextflow.config`), but it's included in the folder name so that re-registering with a different atlas doesn't overwrite a previous run's results under the same path.

### Example Workflow

```bash
# Command
nextflow run main.nf -resume -profile slurm --brain_id MS181 --user_name Lana_Smith

# Input read from:
# lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-data/MS181/Anatomy/MS181.czi

# Outputs published to:
# lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-analysis/Lana_Smith/MS181/MS181_unregistered.xml
# lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-analysis/Lana_Smith/MS181/MS181_registered.xml
# lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-analysis/Lana_Smith/MS181/ch0/<fused_C0>.tiff
# lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-analysis/Lana_Smith/MS181/ch1/<fused_C1>.tiff
# /work/lsens/Lana_Smith/MS181/ch1.ome.zarr  (unless --skip_ome_zarr)
# lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-analysis/Lana_Smith/MS181/registration/MS181_atlasallen_mouse_bluebrain_barrels_10um_bending_energy_weight0.3_grid_spacing4_smoothing_sigma_floating-1/
# lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-analysis/Lana_Smith/MS181/registration/MS181_atlasallen_mouse_bluebrain_barrels_10um_bending_energy_weight0.8_grid_spacing4_smoothing_sigma_floating-1/
```

---

## Notes

1. **Transfer Speed:** Always use SSH paths (`lmsmith@haas056.rcp.epfl.ch:...`) for pipeline input to ensure fast transfer speeds.

2. **Storage Separation:** Input data and output data are stored in separate directory trees due to permission constraints.

3. **Naming Consistency:** Brain identifiers (e.g., `MS181`) are used consistently across input filenames, output folder names, and XML filenames.

4. **Multiple Users:** The output directory structure supports multiple lab members with their own subdirectories.

5. **Parameter Sweeps:** When running brainreg with multiple parameter combinations, each combination gets its own output subdirectory.

---

## TODO

- [x] Determine correct SSH path for output directory → `lmsmith@haas056.rcp.epfl.ch:/mnt/lsens-analysis/`
- [ ] Confirm whether output directories need write/modify permissions
- [ ] Document expected output file sizes for storage planning
- [ ] Set up automated cleanup of intermediate files if needed
