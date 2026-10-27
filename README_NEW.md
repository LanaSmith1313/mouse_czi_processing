# Mouse CZI Processing Pipeline

A [Nextflow](https://www.nextflow.io/) pipeline that turns raw Zeiss light-sheet **CZI** files of whole mouse brains into stitched, fused, atlas-registered volumes, plus GPU spot detection on the result.

```
CZI  ──►  BigStitcher (stitch + fuse)  ──►  per-channel TIFFs  ──►  brainreg (atlas registration)
                                                  │
                                                  └──►  OME-Zarr (ch1)  ──►  Spotiflow (GPU spot detection)
```

It is built for the **SCITAS Jed** cluster at EPFL (with GPU work sent to **Kuma**), and reads/writes the LSENS NAS over SSH. It can also run locally on a single machine for testing.

---

## Contents

1. [What the pipeline does](#1-what-the-pipeline-does)
2. [Requirements](#2-requirements)
3. [Installation and one-time setup](#3-installation-and-one-time-setup)
4. [Configuration](#4-configuration)
5. [Running the pipeline](#5-running-the-pipeline)
6. [Outputs](#6-outputs)
7. [Monitoring, failures and resuming](#7-monitoring-failures-and-resuming)
8. [Local / development setup](#8-local--development-setup)
9. [Using the pipeline on other clusters or setups](#9-using-the-pipeline-on-other-clusters-or-setups)
10. [Troubleshooting](#10-troubleshooting)
11. [Repository layout](#11-repository-layout)

---

## 1. What the pipeline does

| # | Stage | Process(es) | Runs on |
|---|---|---|---|
| 1 | **Stage input** — copy the CZI from the NAS to scratch (or reuse a pre-staged copy) | `stageFilesRSyncSSH` | Jed |
| 2 | **Create BigStitcher dataset** from the CZI | `makeCziDatasetForBigstitcher` | Jed |
| 3 | **Align channels → align tiles → ICP refinement** | `alignChannelsWithBigstitcher`, `alignTilesWithBigstitcher`, `icpRefinementWithBigstitcher` | Jed (`bigmem`) |
| 4 | *(optional)* **Reorient to ASR** | `reorientToASRWithBigstitcher` | Jed |
| 5 | **Fuse** into one TIFF per channel | `fuseBigStitcherDataset` | Jed (`bigmem`) |
| 6 | **Publish** XMLs + fused channels to the NAS | `publishInitialXmlToSource`, `publishStitchedXmlToSource`, `publishFusedChannelsToSource` | Jed |
| 7 | **Convert ch1 to OME-Zarr** (6-level pyramid) on `/work` | `convertTiffToOmeZarr`, `publishOmeZarr` | Jed (`bigmem`) |
| 8 | **Spotiflow spot detection** on the OME-Zarr | `spotiflowDetectKuma` | Kuma (2× H100) |
| 9 | **Register to a BrainGlobe atlas** with brainreg (optionally a parameter sweep) | `brainregRunRegistration` | Jed (`bigmem`) |
| 10 | **Publish registration results** to the NAS | `copyResultsToImageFolder` | Jed |

Every stage runs by default. Each one can be switched off with a `--skip_*` flag (see [Skip flags](#skip-flags)).

Tools that the pipeline installs **itself** on first run and caches for later runs:

- **Fiji** with the BigStitcher, PTBIOP and Zeiss Quick Start Reader update sites
- a **brainreg** Python environment (`brainreg==1.0.13`)
- an **OME-Zarr** Python environment (`iohub`, `tifffile`, …)
- the **BrainGlobe atlas** set in `nextflow.config`

The only thing you install by hand is the **Spotiflow** environment on Kuma, because it needs a GPU node (see [step 3.6](#36-spotiflow-on-kuma-one-time-gpu-setup)).

---

## 2. Requirements

### Accounts and access

| You need | Why |
|---|---|
| A SCITAS account with access to **Jed** (`standard` and `bigmem` partitions) | Runs the pipeline |
| A SCITAS account with access to **Kuma** (`h100` partition) | Spotiflow GPU step (skip it with `--skip_spotiflow` if you have no access) |
| SSH access to the NAS gateway **`haas056.rcp.epfl.ch`** | Reads CZIs from `/mnt/lsens-data`, writes results to `/mnt/lsens-analysis` |
| Membership of a Unix group with a folder on **`/work/<group>/`** (e.g. `/work/lsens`) | Shared caches, OME-Zarr and Spotiflow output |

### Software on Jed

| Software | How you get it |
|---|---|
| Java 17+ | `module load openjdk/21.0.0_35-h27dssk` |
| Nextflow | Self-install, see [step 3.2](#32-install-nextflow) |
| Apptainer | Already on SCITAS clusters (the pipeline runs `python:3.11` containers through it) |
| `git`, `rsync`, `ssh`, `screen` | Already on SCITAS clusters |

### Software on Kuma (Spotiflow only)

| Software | How you get it |
|---|---|
| micromamba | See [step 3.6](#36-spotiflow-on-kuma-one-time-gpu-setup) |
| The `spotiflow_12` environment | Built from `bin/spotiflow_env.yml` |
| A trained Spotiflow model | Copied to `/work/<group>/models/` |

---

## 3. Installation and one-time setup

Do these steps once per user. Everything below runs **on the Jed login node** unless stated otherwise.

### 3.1 Set up passwordless SSH

The pipeline runs `rsync`/`ssh` without a terminal, so key-based login must work with no password prompt.

```bash
# On Jed: create a key if you don't have one (press Enter at the passphrase prompt)
ssh-keygen -t ed25519

# Copy it to the NAS gateway and to Kuma
ssh-copy-id <your_gaspar>@haas056.rcp.epfl.ch
ssh-copy-id <your_gaspar>@kuma.hpc.epfl.ch

# Test: both must print the hostname without asking for anything
ssh -o BatchMode=yes <your_gaspar>@haas056.rcp.epfl.ch hostname
ssh -o BatchMode=yes <your_gaspar>@kuma.hpc.epfl.ch hostname
```

### 3.2 Install Nextflow

```bash
module load openjdk/21.0.0_35-h27dssk

mkdir -p ~/.local/bin
cd ~/.local/bin
curl -s https://get.nextflow.io | bash
chmod +x nextflow

# Make sure ~/.local/bin is on your PATH (add this line to ~/.bashrc)
export PATH="$HOME/.local/bin:$PATH"

nextflow -version
```

The full instructions are in the [Nextflow docs](https://www.nextflow.io/docs/latest/install.html#self-install).

> **Tip:** put `module load openjdk/21.0.0_35-h27dssk` in your `~/.bashrc` too, so Java is always loaded when you start Nextflow.

### 3.3 Clone the repository

```bash
cd ~
git clone https://github.com/LanaSmith1313/mouse_czi_processing.git
cd mouse_czi_processing
```

The original project (by Nicolas Chiaruttini, BIOP) is at `https://github.com/NicoKiaru/mouse_czi_processing`.

### 3.4 Personalise `nextflow.config`

Open `nextflow.config` and replace the defaults that point at Lana's account:

```groovy
params {
    ssh_host     = "<your_gaspar>@haas056.rcp.epfl.ch"   // NAS gateway
    kuma_host    = "<your_gaspar>@kuma.hpc.epfl.ch"      // GPU cluster
    notify_email = "<you>@epfl.ch"                      // run summary (null to disable)
    ...
}

mail {
    from = '<you>@epfl.ch'
}
```

You can also leave the file unchanged and pass these on the command line each time (`--ssh_host ... --kuma_host ... --notify_email ...`).

### 3.5 Check the shared cache folders

Under `-profile slurm`, caches go to `/work/<group>/`. `<group>` is your primary Unix group with the `-unit` suffix removed (`lsens-unit` → `lsens`):

```
/work/<group>/
├── fiji_mouse_czi_processing/   # Fiji install           (created automatically)
├── envs/                        # brainreg + OME-Zarr envs (created automatically)
│   └── spotiflow_12/            # Spotiflow env          (you create it, step 3.6)
├── atlas/                       # BrainGlobe atlases     (created automatically)
├── models/                      # Spotiflow models       (you copy them, step 3.6)
├── apptainer_cache/             # container images      (created automatically)
└── <First_Last>/                # your OME-Zarr + Spotiflow results
```

Check that the group name resolves and the folder is writable:

```bash
id -gn                     # e.g. lsens-unit
ls -ld /work/lsens         # must exist and be writable by you
```

If `id -gn` does not give the right group, replace the `${['id', '-gn'].execute()...}` expressions in the `slurm` profile of `nextflow.config` with your group name.

The Nextflow work directory is `/scratch/$USER/nf`. Scratch is **not backed up** and old files are purged automatically.

### 3.6 Spotiflow on Kuma (one-time GPU setup)

Skip this section if you will always run with `--skip_spotiflow`.

**a. Log in to Kuma and install micromamba** at the path the batch script expects (`~/.local/bin/micromamba`, root `~/micromamba`):

```bash
ssh <your_gaspar>@kuma.hpc.epfl.ch
"${SHELL}" <(curl -L micro.mamba.pm/install.sh)
# Accept the defaults: binary in ~/.local/bin, prefix in ~/micromamba
```

If you put micromamba somewhere else, set `MAMBA_EXE` / `MAMBA_ROOT_PREFIX` in your environment.

**b. Create the environment** on the shared `/work` (preferably from a GPU node, so the CUDA torch wheels are picked up):

```bash
cd ~/mouse_czi_processing        # clone the repo on Kuma as well, or use the Jed copy via /home
micromamba create -y -p /work/<group>/envs/spotiflow_12 -f bin/spotiflow_env.yml
```

**c. Put the model in place.** The folder name must match `spotiflow_model` in `nextflow.config`:

```
/work/<group>/models/spotiflow_scratch_annotated_clean_20251211_cropsize64_grid1_sigma3/
```

**d. Create the log folder.** The batch script writes Slurm logs to `~/logs/`, and the job fails immediately if the folder is missing:

```bash
mkdir -p ~/logs
```

### 3.7 Check the installation

Back on Jed:

```bash
cd ~/mouse_czi_processing
module load openjdk/21.0.0_35-h27dssk

# 1. Print resolved paths, run nothing
nextflow run main.nf -profile slurm --brain_id MS181 --user_name First_Last --dry_run

# 2. Stage one CZI and print its voxel sizes (also installs Fiji the first time)
nextflow run main.nf -resume -profile slurm --brain_id MS181 --user_name First_Last --check_voxels
```

The first real run takes longer than later ones because Fiji, the Python environments and the atlas are downloaded and cached.

---

## 4. Configuration

All settings are in [`nextflow.config`](nextflow.config). Any `params` value can be overridden on the command line with `--name value`.

### Data locations

| Param | Default | Meaning |
|---|---|---|
| `ssh_host` | `lmsmith@haas056.rcp.epfl.ch` | NAS gateway |
| `input_base_path` | `/mnt/lsens-data` | Root of the raw data tree |
| `output_base_path` | `/mnt/lsens-analysis` | Root of the analysis tree |
| `brain_id` | — | One or more brain IDs, comma-separated (`MS181,LS010`) |
| `user_name` | — | Output folder name, `First_Last`. **Required** for anything to be published |
| `input` | — | Explicit input path(s) instead of `brain_id` |

With `--brain_id`, the paths are built like this (see [DATA_LAYOUT.md](DATA_LAYOUT.md)):

- **Input:** `<ssh_host>:<input_base_path>/<brain_id>/Anatomy/<brain_id>.czi`
- **Output:** `<ssh_host>:<output_base_path>/<user_name>/<brain_id>/`

### BigStitcher (`params.bigstitcher`)

| Setting | Default | Meaning |
|---|---|---|
| `channel_alignment.filter_min_r` | `0.7` | Minimum correlation to keep a channel shift |
| `channel_alignment.filter_max_shift` | `50` | Maximum total channel shift (px) to keep; larger links are dropped and the channel falls back to stage metadata |
| `tile_alignment.use_channel` | `0` | Channel used to align tiles |
| `tile_alignment.filter_min_r` | `0.7` | Minimum correlation to keep a tile shift |
| `icp_refinement.*` | Simple, 8/8/4, <5 px | ICP refinement options |
| `reorientation.raw_orientation` | `IPR` | Orientation of the raw data (1st letter = Z, 2nd = Y, 3rd = X) |
| `reorientation.reorient_to_asr` | `false` | Reorient to ASR before fusion |
| `fusion_config.downsample` | `1` | Downsampling applied at fusion |
| `fusion_config.fusion_method` | `SMOOTH AVERAGE` | Fusion method |

### Registration (`params.brainreg`)

| Setting | Default | Meaning |
|---|---|---|
| `atlas` | `perens_lsfm_mouse_20um` | BrainGlobe atlas name |
| `channel_used_for_registration` | `0` | Channel registered to the atlas. The other channels are transformed with it |
| `bending_energy_weight` | `[0.7, 0.8, 0.9]` | **Sweepable** |
| `grid_spacing` | `[-20, -30, -40]` | **Sweepable** |
| `smoothing_sigma_floating` | `['-1']` | **Sweepable** |

**Parameter sweeps:** every combination of the sweepable lists is run as a separate registration. The defaults above give 3 × 3 × 1 = **9 registrations per brain**. For a single registration, keep one value in brackets:

```groovy
bending_energy_weight = [0.8]
grid_spacing = [-30]
smoothing_sigma_floating = ['-1']
```

### Spotiflow

| Param | Default | Meaning |
|---|---|---|
| `kuma_host` | `lmsmith@kuma.hpc.epfl.ch` | SSH target for the GPU cluster |
| `spotiflow_model` | `spotiflow_scratch_annotated_clean_…` | Model folder name under `models_dir` |
| `spotiflow_version` | `spotiflow_lsfm_v6_scratch_preds` | Label used in the output path |
| `spotiflow_sbatch` | `bin/sbatch_spotiflow.batch` | GPU batch script (2× H100, 32 CPUs, 180 GB) |

### Run behaviour

| Param | Default | Meaning |
|---|---|---|
| `max_concurrent_transfers` | `1` | How many NAS ↔ cluster transfers run at once |
| `notify_email` | `lana.smith@epfl.ch` | Where the end-of-run summary is emailed (`null` or `''` to disable) |

### Profiles

| Profile | Use it for | Notes |
|---|---|---|
| `slurm` | Production runs on Jed | Submits to Slurm. Caches go in `/work/<group>/`, work dir is `/scratch/$USER/nf` |
| `local` | Testing on one machine | Runs everything locally with Apptainer. OME-Zarr and Spotiflow are skipped |
| `test` | Small demo file | Combine with `local`: `-profile local,test` |

Slurm resources per process (from the `slurm` profile):

| Processes | Partition | Memory | CPUs | Time |
|---|---|---|---|---|
| Default | `standard` | 64 GB | 16 | 4 h |
| Align channels / tiles, fuse, OME-Zarr | `bigmem` | 480 GB | 40 | 8 h |
| ICP refinement | `standard` | 96 GB | 16 | 12 h |
| brainreg registration | `bigmem` | 150 GB | 32 | 8 h |
| Publish fused channels | `standard` | 8 GB | 2 | 12 h |
| Spotiflow (Jed side, waits for Kuma) | `standard` | 2 GB | 1 | 1 day |
| Staging / small publishes | login node | 2 GB | 1 | — |

---

## 5. Running the pipeline

### Standard run on Jed

The pipeline keeps running on the login node for many hours, so **always start it inside `screen`**:

```bash
screen -S brains_batch1
module load openjdk/21.0.0_35-h27dssk
cd ~/mouse_czi_processing

nextflow run main.nf -resume -profile slurm --brain_id MS181 --user_name First_Last

# Several brains at once
nextflow run main.nf -resume -profile slurm --brain_id MS181,MS182,LS010 --user_name First_Last
```

Detach with `Ctrl+a` then `d`. Reattach later with `screen -r brains_batch1` (`screen -ls` lists sessions).

> A trace is always written to `pipeline_trace.txt` (it is enabled in the config). You do not need `-with-trace`.

### Skip flags

| Flag | Skips |
|---|---|
| `--skip_results_transfer` | Publishing the XMLs and fused channel TIFFs to the NAS |
| `--skip_ome_zarr` | The ch1 → OME-Zarr conversion. Spotiflow then runs on an existing zarr on `/work`, if there is one |
| `--skip_spotiflow` | Spotiflow spot detection on Kuma |
| `--skip_registration` | brainreg (stops after fusion) |
| `--skip_registration_transfer` | Copying registration results to the NAS |

```bash
# Stitch + fuse only: no transfers, no zarr/spotiflow, no registration
nextflow run main.nf -resume -profile slurm --brain_id MS181 --user_name First_Last \
    --skip_results_transfer --skip_ome_zarr --skip_registration

# Re-run only Spotiflow on an OME-Zarr that already exists on /work
nextflow run main.nf -resume -profile slurm --brain_id MS181 --user_name First_Last \
    --skip_ome_zarr --skip_registration --skip_results_transfer
```

### Other modes

```bash
# Dry run: print every input/output path and exit
nextflow run main.nf -profile slurm --brain_id MS181 --user_name First_Last --dry_run

# Voxel check: stage the CZI, print original / post-ASR / fused voxel sizes and anisotropy, then exit
nextflow run main.nf -resume -profile slurm --brain_id MS181 --user_name First_Last --check_voxels

# OME-Zarr only: convert already-published fused ch1 TIFFs (no stitching, fusion or registration)
nextflow run main.nf -entry omeZarrOnly -profile slurm --brain_id MS190,MS191 --user_name First_Last

# Explicit SSH input instead of --brain_id
nextflow run main.nf -resume -profile slurm \
    --input user@host:/remote/path/file.czi --user_name First_Last
```

### Pre-staging large CZIs (optional)

Copying a CZI from the NAS can take hours. If a file already exists at

```
/scratch/$USER/czi_prestage/<brain_id>.czi
```

the staging step symlinks it and does not download it again. You can use this to copy files in advance, for example during the night.

---

## 6. Outputs

For `--brain_id MS181 --user_name First_Last`:

**On the NAS** (`haas056:/mnt/lsens-analysis/First_Last/MS181/`)

```
MS181/
├── MS181_unregistered.xml        # BigStitcher dataset before stitching
├── MS181_registered.xml          # BigStitcher dataset after stitching
├── ch0/<fused>_C0.tiff           # fused channel 0
├── ch1/<fused>_C1.tiff           # fused channel 1
└── registration/
    └── MS181_atlas<atlas>_bending_energy_weight<x>_grid_spacing<y>_smoothing_sigma_floating<z>/
                                  # one folder per parameter combination
```

**On `/work/<group>/First_Last/`**

```
MS181/ch1.ome.zarr                                         # 6-level OME-Zarr pyramid of ch1
detection_results/<spotiflow_version>/MS181/               # Spotiflow predictions
```

**In the launch directory**

```
pipeline_trace.txt                      # per-task status, duration, work dir
pipeline_failures_<run_name>.txt        # end-of-run summary (also emailed)
.nextflow.log                           # full Nextflow log
```

More detail on the folder conventions is in [DATA_LAYOUT.md](DATA_LAYOUT.md).

---

## 7. Monitoring, failures and resuming

- **One bad brain does not stop the batch.** A failed task is retried once and then ignored, so only that brain's later steps are dropped.
- **At the end of each run**, `pipeline_failures_<run_name>.txt` lists each failed task: *which* (process + brain), *where* (work directory) and *why* (last 20 lines of `.command.err`). The same summary is emailed to `notify_email`.
- **To resume**, run the same command again with `-resume`. Finished steps are taken from the cache.
- **To inspect a failed task**, `cd` into its work directory (shown in the summary) and read `.command.sh`, `.command.err` and `.command.log`.
- **Spotiflow logs** are on Kuma in `~/logs/<jobid>.out` / `.err`.

Useful commands while a run is going:

```bash
squeue -u $USER                       # your Slurm jobs on Jed
ssh <you>@kuma.hpc.epfl.ch squeue -u $USER   # Spotiflow jobs on Kuma
tail -f .nextflow.log
nextflow log                          # list past runs
```

---

## 8. Local / development setup

For development or testing without the cluster:

1. Install Java 17+, [Nextflow](https://www.nextflow.io/docs/latest/install.html) and [Apptainer](https://apptainer.org/docs/admin/main/installation.html). On Windows, use WSL.
2. (Optional) Install VS Code with the Nextflow extension.
3. Download the small demo dataset and save it as `test_data/Small.czi`:
   ```bash
   mkdir -p test_data
   wget -O test_data/Small.czi \
     "https://zenodo.org/records/8305531/files/Demo%20LISH%204x8%2015pct%20647.czi?download=1"
   ```
4. Run it. See the warning below first.

> ⚠️ **Known limitation:** `main.nf` currently accepts only SSH-style inputs (`user@host:/path/file.czi`). The branch that handled plain local paths is commented out ([main.nf:136-142](main.nf#L136-L142)), so `-profile local --input /path/file.czi` and `-profile local,test` silently process nothing. Until that is fixed, run on a workstation the way [section 9.4](#94-single-workstation-no-scheduler) describes: SSH to yourself, with the `slurm` profile plus a config that switches the executor to `local`.

Caches go under `./work/` for local runs. OME-Zarr and Spotiflow are turned off in the `local` profile.

---

## 9. Using the pipeline on other clusters or setups

The pipeline is built around EPFL's infrastructure, but nothing in it depends on EPFL itself. To run it elsewhere, change the site-specific settings, ideally in your own config file, so `nextflow.config` stays untouched and you can still `git pull` updates.

### 9.1 What is site-specific

| What | Default (EPFL) | Where to change it |
|---|---|---|
| File server holding raw data and results | `lmsmith@haas056.rcp.epfl.ch` | `params.ssh_host` |
| Raw data root / analysis root | `/mnt/lsens-data` / `/mnt/lsens-analysis` | `params.input_base_path`, `params.output_base_path` |
| Raw data folder convention | `<brain_id>/Anatomy/<brain_id>.czi` | [main.nf:74](main.nf#L74), or skip `--brain_id` and pass `--input` paths |
| Scheduler | Slurm | `process.executor` (see [9.3](#93-a-different-scheduler-pbs-lsf-sge-)) |
| Partition names | `standard`, `bigmem` | `process.queue` and the `withName` blocks |
| Memory for the heavy steps | 480 GB (align, fuse, OME-Zarr), 150 GB (brainreg) | `withName` blocks (Fiji gets 80 % of the task memory) |
| Nextflow work directory | `/scratch/$USER/nf` | `workDir` |
| Shared caches (Fiji, envs, atlas, models) and OME-Zarr output | `/work/<group>/…` | `params.fiji_cache_dir`, `env_cache_dir`, `atlas_cache_dir`, `models_dir`, `ome_zarr_output_base` |
| Container cache | `/work/<group>/apptainer_cache` | `apptainer.cacheDir` |
| Pre-staging folder | `/scratch/$USER/czi_prestage/` | [modules/upload_data.nf:259](modules/upload_data.nf#L259) |
| Java | `module load openjdk/21.0.0_35-h27dssk` | Whatever your cluster provides (Java 17+) |
| GPU cluster for Spotiflow | Kuma, `h100` partition | `params.kuma_host` and the `#SBATCH` lines in [bin/sbatch_spotiflow.batch](bin/sbatch_spotiflow.batch) |
| Run-summary email | local `sendmail` → `lana.smith@epfl.ch` | `params.notify_email` (set to `null` if the host has no mail) |

### 9.2 Recommended: a site config file

Create a file such as `conf/mysite.config` (any name works):

```groovy
// conf/mysite.config — overrides for <your institute> cluster
params {
    ssh_host             = "me@fileserver.example.org"
    input_base_path      = "/data/raw"
    output_base_path     = "/data/analysis"

    fiji_cache_dir       = "/shared/mygroup/fiji_mouse_czi_processing"
    env_cache_dir        = "/shared/mygroup/envs"
    atlas_cache_dir      = "/shared/mygroup/atlas"
    models_dir           = "/shared/mygroup/models"
    ome_zarr_output_base = "/shared/mygroup"

    notify_email         = null            // or your address
    skip_spotiflow       = true            // until a GPU setup is configured (9.6)
}

workDir            = "/scratch/me/nf"
apptainer.cacheDir = "/shared/mygroup/apptainer_cache"

process {
    queue = 'normal'

    withName: 'alignChannelsWithBigstitcher|alignTilesWithBigstitcher|fuseBigStitcherDataset|convertTiffToOmeZarr' {
        queue  = 'highmem'
        memory = '480 GB'
        cpus   = 32
        time   = '12h'
    }
    withName: 'brainregRunRegistration' {
        queue = 'highmem'
    }
    withName: 'icpRefinementWithBigstitcher|publishFusedChannelsToSource|spotiflowDetectKuma' {
        queue = 'normal'
    }
}
```

Then run with the `slurm` profile **and** your file:

```bash
nextflow run main.nf -resume -profile slurm -c conf/mysite.config \
    --brain_id MS181 --user_name First_Last
```

Settings in a `-c` file override those in `nextflow.config`.

> **Keep `slurm` in the profile name.** The pipeline only stages input files when the active profile name contains `slurm` ([main.nf:167](main.nf#L167)). Without staging, the SSH input path goes straight to Fiji and the run fails. Either keep `-profile slurm` and put your changes in the `-c` file, or edit that line.

**How much memory?** The defaults are sized for whole-brain CZIs of several hundred GB. If your nodes have less memory, increase `fusion_config.downsample`, or test on a smaller dataset first.

### 9.3 A different scheduler (PBS, LSF, SGE, …)

Nextflow supports [many executors](https://www.nextflow.io/docs/latest/executor.html). The `slurm` profile sets `executor = 'slurm'` both globally and inside several `withName` blocks, so override every one of them. The transfer steps (`stageFilesRSync`, `publishInitialXmlToSource`, `publishStitchedXmlToSource`, `publishOmeZarr`, `copyResultsToImageFolder`) are pinned to `local` on purpose, so leave those as they are.

```groovy
// conf/mysite.config (continued) — example for PBS Pro
process {
    executor = 'pbspro'
    withName: 'alignChannelsWithBigstitcher|alignTilesWithBigstitcher|fuseBigStitcherDataset|convertTiffToOmeZarr|icpRefinementWithBigstitcher|brainregRunRegistration|publishFusedChannelsToSource|spotiflowDetectKuma' {
        executor = 'pbspro'
    }
}
```

`stageFilesRSyncSSH` runs as a cluster job. Also check that your cluster allows long-running processes on the login node (Nextflow itself and the `local` transfer steps). If it does not, launch Nextflow from an interactive or long-running job instead.

### 9.4 Single workstation (no scheduler)

A large Linux workstation (several hundred GB of RAM for full brains) works with the same approach. Make every step `local` and use SSH to yourself for input and output:

```groovy
// conf/workstation.config
params {
    ssh_host         = "me@localhost"
    input_base_path  = "/data/raw"
    output_base_path = "/data/analysis"
    fiji_cache_dir   = "/data/cache/fiji_mouse_czi_processing"
    env_cache_dir    = "/data/cache/envs"
    atlas_cache_dir  = "/data/cache/atlas"
    models_dir       = "/data/cache/models"
    ome_zarr_output_base = "/data/zarr"
    skip_spotiflow   = true
    notify_email     = null
}
workDir            = "/data/nf_work"
apptainer.cacheDir = "/data/cache/apptainer"
executor.cpus      = 32          // what the machine has
executor.memory    = '500 GB'

process {
    executor = 'local'
    withName: '.*' { executor = 'local'; queue = null }
}
```

```bash
# One-time: allow passwordless SSH to yourself
ssh-keygen -t ed25519                       # if you have no key yet
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
ssh -o BatchMode=yes me@localhost hostname  # must not prompt

nextflow run main.nf -resume -profile slurm -c conf/workstation.config \
    --brain_id MS181 --user_name First_Last
```

Lower the `memory` / `cpus` in the `withName` blocks if a task asks for more than the machine has. Nextflow will not start a local task that requests more than `executor.memory`.

### 9.5 Data on a shared filesystem instead of a remote server

All input and output goes through `ssh` + `rsync` to `params.ssh_host`. If your data is on a filesystem the cluster already mounts, point `ssh_host` at a machine that sees that filesystem and that you can reach without a password **from both the login node and the compute nodes**. Usually that is the login node's hostname (`me@login1.mycluster.org`). `input_base_path` and `output_base_path` are then ordinary paths on that filesystem.

If your raw data does not follow `<brain_id>/Anatomy/<brain_id>.czi`, either:

- pass explicit paths: `--input me@host:/data/raw/mouse1.czi,me@host:/data/raw/mouse2.czi --user_name First_Last` (file basenames must be unique and are used as the brain ID), or
- change the pattern at [main.nf:74](main.nf#L74).

### 9.6 Spotiflow (GPU) elsewhere

The Spotiflow step works anywhere that meets these conditions:

1. Passwordless SSH from the Nextflow host to `params.kuma_host`, where `sbatch`, `squeue` and `sacct` work (so the GPU cluster must use Slurm, or you adapt [modules/spotiflow.nf](modules/spotiflow.nf)).
2. The GPU nodes see `ome_zarr_output_base`, `models_dir` and `env_cache_dir` **at the same paths** as the main cluster.

To set it up:

- Set `kuma_host` to your GPU login node. If your main cluster has GPU partitions itself, use its own login node.
- Edit the `#SBATCH` lines in [bin/sbatch_spotiflow.batch](bin/sbatch_spotiflow.batch): `--partition`, `--qos`, `--gpus`, `--mem`, `--time` and the `~/logs` output path.
- Create the environment at `<env_cache_dir>/spotiflow_12` and place the model in `<models_dir>/<spotiflow_model>`, as in [step 3.6](#36-spotiflow-on-kuma-one-time-gpu-setup).

If none of this is possible, run with `--skip_spotiflow` and run `spotiflow-predict` on the OME-Zarr later, by hand.

### 9.7 Compute nodes without internet access

These steps download software the first time they run, and they run as cluster jobs:

| Process | Downloads |
|---|---|
| `setupFiji` | Fiji + update sites (needs `wget` and `unzip`; it tries `sudo apt install unzip` if `unzip` is missing) |
| `brainregEnvInstall`, `omeZarrEnvInstall` | Python packages from PyPI |
| `downloadAtlas` | The BrainGlobe atlas |

If the compute nodes are offline, run these four steps on the login node:

```groovy
process {
    withName: 'setupFiji|brainregEnvInstall|omeZarrEnvInstall|downloadAtlas' {
        executor = 'local'
    }
}
```

You can also copy filled cache folders (`fiji_cache_dir`, `env_cache_dir`, `atlas_cache_dir`) from a machine that already has them. The `python:3.11` container image must also be pullable from Docker Hub, or already be in `apptainer.cacheDir`.

### 9.8 Containers

The Python steps run in the `python:3.11` image through **Apptainer**. Fiji runs directly on the host, so it needs a standard x86-64 Linux. To use Docker instead of Apptainer, add this to your site config:

```groovy
apptainer.enabled = false
docker.enabled    = true
```

### 9.9 Checklist for a new site

1. `--dry_run` prints the input and output paths you expect.
2. `ssh -o BatchMode=yes <ssh_host> ls <input_base_path>/<brain_id>` works from the login node **and** from a compute node (`srun` / `qsub -I`).
3. `--check_voxels` stages one file and installs Fiji.
4. A first run with `--skip_registration --skip_ome_zarr --skip_spotiflow` produces fused TIFFs.
5. Then turn registration, OME-Zarr and Spotiflow back on, one at a time.

---

## 10. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Permission denied (publickey)` or the run hangs at staging | Passwordless SSH to `haas056` is not set up. Redo [step 3.1](#31-set-up-passwordless-ssh) |
| `Duplicate basenames found in input files` | Two inputs have the same filename. Every CZI must have a unique name |
| Nothing is published to the NAS | `--user_name` is missing (the log shows a warning) |
| Spotiflow fails right away with no output | `~/logs` is missing on Kuma, the env is not at `/work/<group>/envs/spotiflow_12`, or the model folder name is wrong |
| `failed to submit spotiflow job on Kuma after retries` | SSH Jed → Kuma is not passwordless, or Kuma is rate-limiting SSH. Rerun with `-resume` |
| `java: command not found` / Nextflow will not start | Run `module load openjdk/21.0.0_35-h27dssk` |
| The run dies after a few hours on the login node | It was not started inside `screen`, or the SSH session dropped |
| Cache folders end up in the wrong `/work/...` | `id -gn` returned an unexpected group. Hard-code the group in the `slurm` profile |

---

## 11. Repository layout

```
mouse_czi_processing/
├── main.nf                 # Main workflow (+ omeZarrOnly entry point, run summary)
├── nextflow.config         # Parameters, profiles, Slurm resources
├── modules/
│   ├── fiji.nf             # Fiji install / cache
│   ├── upload_data.nf      # rsync staging and publishing to/from the NAS
│   ├── bigstitcher.nf      # Dataset creation, alignment, ICP, ASR, fusion, voxel sizes
│   ├── brainreg.nf         # brainreg env, atlas download, channel organisation, registration
│   ├── ome_zarr.nf         # OME-Zarr env, conversion, publish
│   └── spotiflow.nf        # Kuma job submission and polling
├── bin/                    # Fiji macros (.ijm), Groovy scripts, Python helpers,
│                           # Spotiflow sbatch script and env file
├── lib/PathUtils.groovy    # Basename / key helpers used to match files across stages
├── DATA_LAYOUT.md          # NAS folder conventions
└── readme.md               # Original README (pipeline flowchart)
```

---

## Credits

Pipeline by **Nicolas Chiaruttini** ([BIOP, EPFL](https://biop.epfl.ch/)), extended by **Lana Smith** (LSENS, EPFL). It combines [BIOP/lightsheet-brain-workflows](https://github.com/BIOP/lightsheet-brain-workflows) with the cluster tooling from [LanaSmith1313/cluster_analysis](https://github.com/LanaSmith1313/cluster_analysis).

Built on [BigStitcher](https://imagej.net/plugins/bigstitcher/), [BrainGlobe / brainreg](https://brainglobe.info/), [iohub](https://github.com/czbiohub-sf/iohub) and [Spotiflow](https://github.com/weigertlab/spotiflow).
