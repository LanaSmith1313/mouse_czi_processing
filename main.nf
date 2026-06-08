#!/usr/bin/env nextflow
include { setupFiji; useCachedFiji } from './modules/fiji'

include { stageFilesRSync; copyResultsToImageFolder; stageFilesRSyncSSH; publishFusedChannelsToSource } from './modules/upload_data'

include {
    makeCziDatasetForBigstitcher;
    alignChannelsWithBigstitcher;
    alignTilesWithBigstitcher;
    icpRefinementWithBigstitcher;
    reorientToASRWithBigstitcher;
    fuseBigStitcherDataset;
    getVoxelSizes;
    getVoxelSizes as getOriginalVoxelSizes;
    publishInitialXmlToSource;
    publishStitchedXmlToSource; } from './modules/bigstitcher'

include { brainregEnvInstall;
          brainregTestEnv;
          brainregRunRegistration;
          downloadAtlas;
          organizeChannelsForBrainreg } from './modules/brainreg'

include { omeZarrEnvInstall; convertTiffToOmeZarr; publishOmeZarr; stageFusedCh1 } from './modules/ome_zarr'
include { spotiflowDetectKuma } from './modules/spotiflow'

// Helper function to ensure parameter is a list
def ensureList(param) {
    return param instanceof List ? param : [param]
}

// Map orientation letter to anatomical axis pair
def letterToAxis(letter) {
    switch(letter.toUpperCase()) {
        case 'A': case 'P': return 'AP'
        case 'S': case 'I': return 'SI'
        case 'R': case 'L': return 'RL'
        default: throw new IllegalArgumentException("Unknown orientation letter: ${letter}")
    }
}

// Permute voxel sizes from any orientation to ASR
// Orientation convention: 1st letter = Z, 2nd = Y, 3rd = X
// ASR target: Z=A(AP), Y=S(SI), X=R(RL)
def permuteVoxelsToASR(String orientation, double vx, double vy, double vz) {
    def orig = orientation.toUpperCase()
    // Original axes: which anatomical axis is on each image axis
    def orig_x_axis = letterToAxis(orig[2])  // 3rd letter = X
    def orig_y_axis = letterToAxis(orig[1])  // 2nd letter = Y
    def orig_z_axis = letterToAxis(orig[0])  // 1st letter = Z

    def orig_axes = [orig_x_axis, orig_y_axis, orig_z_axis]
    def orig_voxels = [vx, vy, vz]

    // ASR target: X=RL, Y=SI, Z=AP
    def target_axes = ['RL', 'SI', 'AP']

    def new_voxels = target_axes.collect { target_ax ->
        def idx = orig_axes.indexOf(target_ax)
        if (idx < 0) throw new IllegalArgumentException(
            "Cannot find axis ${target_ax} in orientation ${orig} (axes: ${orig_axes})")
        orig_voxels[idx]
    }
    return new_voxels  // [new_vx, new_vy, new_vz]
}

workflow {

    // Resolve input: construct SSH paths from brain_id, or use --input directly
    def resolved_input = params.input
    if (params.brain_id && !params.input) {
        def brain_ids = params.brain_id.split(',').collect { it.trim() }
        def constructed = brain_ids.collect { id ->
            "${params.ssh_host}:${params.input_base_path}/${id}/Anatomy/${id}.czi"
        }
        resolved_input = constructed.join(',')
        log.info "Constructed input paths from brain_id: ${resolved_input}"
    }

    // Validate user_name is set when publishing is needed
    if (resolved_input && resolved_input.contains('@') && !params.user_name) {
        log.warn "WARNING: --user_name not set. Output publishing to analysis directory will be disabled."
    }

    // Dry run: print resolved paths and exit
    if (params.dry_run) {
        log.info "========================================="
        log.info "  DRY RUN - No processing will be done"
        log.info "========================================="
        if (resolved_input) {
            def dry_run_files = resolved_input.split(',').collect { it.trim() }
            dry_run_files.each { path_str ->
                def key = PathUtils.getBaseKey(path_str)
                log.info ""
                log.info "Brain: ${key}"
                log.info "  Input:  ${path_str}"
                if (params.user_name) {
                    def output_base = "${params.ssh_host}:${params.output_base_path}/${params.user_name}/${key}"
                    log.info "  Output: ${output_base}/"
                    log.info "    XML:          ${output_base}/${key}_unregistered.xml"
                    log.info "    XML:          ${output_base}/${key}_registered.xml"
                    log.info "    Channels:     ${output_base}/ch0/, ch1/, ..."
                    if (params.export_ome_zarr) {
                        log.info "    OME-Zarr:     ${params.ome_zarr_output_base}/${params.user_name}/${key}/ch1.ome.zarr"
                    }
                    log.info "    Registration: ${output_base}/registration/${key}_<param_combo>/"
                } else {
                    log.info "  Output: NOT CONFIGURED (set --user_name to enable)"
                }
            }
        } else {
            log.info "No input specified (use --brain_id or --input)"
        }
        log.info ""
        log.info "========================================="
        return
    }

    // Check if Fiji already exists, otherwise set it up
    if (file("${params.fiji_cache_dir}/fiji_installation").exists()) {
        fiji_path = Channel.value("${params.fiji_cache_dir}/fiji_installation")
        log.info "Using cached Fiji installation at: ${params.fiji_cache_dir}/fiji_installation"
    } else {
        log.info "Setting up new Fiji installation..."
        fiji_path = setupFiji()
    }
    
    // Handle input files - properly split comma-separated input
    if (resolved_input) {
        // Split by comma, trim whitespace, and create channel
        input_files = resolved_input.split(',').collect { it.trim() }
        //images = Channel.fromList(input_files).map { file(it) }

        // Separate SSH paths from local paths
        images = Channel.fromList(input_files).map { path_str ->
            if (path_str.contains('@') && path_str.contains(':')) {
                // This is an SSH path - don't try to convert to file object
                return path_str
            } /*else {
                // This is a local path
                return tuple('local', file(path_str))
            }*/
        }

        // Check for duplicate basenames - unique key is required!
        def basenames = input_files.collect {
            def basename = PathUtils.extractBasename(it)
            return basename
        }

        def uniqueBasenames = basenames.unique()
        if (input_files.size() != uniqueBasenames.size()) {
            throw new IllegalArgumentException(
                "Duplicate basenames found in input files: ${uniqueBasenames[0]}. " +
                "All input files must have unique basenames."
            )
        }

        // Debug: show what files were found BEFORE processing
        images.view { "Found input file: $it" }
    } else {
        log.info "WARNING: no input file defined - running the pipeline will only install tools without using them"
        images = Channel.empty()
    }
    
    // Conditionally stage files based on profile or parameter
    def shouldStageFiles = workflow.profile.contains('slurm')
    
    if (shouldStageFiles) {
        log.info "File staging enabled (profile: ${workflow.profile}, stage_files: ${params.stage_files})"
        staged_files = stageFilesRSyncSSH(images)
    } else {
        log.info "File staging disabled - using files directly"
        staged_files = images
    }
    
    // Check voxels mode: extract original voxel sizes from CZI and show fusion preview
    if (params.check_voxels) {
        log.info "========================================="
        log.info "  CHECK VOXELS - Voxel size analysis"
        log.info "========================================="
        getOriginalVoxelSizes(staged_files, fiji_path)
        getOriginalVoxelSizes.out.voxel_sizes.view { name, x, y, z ->
            def vx = x as double
            def vy = y as double
            def vz = z as double
            def reorient = params.bigstitcher.reorientation

            // Permute voxels if ASR reorientation is enabled
            def eff_vx = vx, eff_vy = vy, eff_vz = vz
            if (reorient.reorient_to_asr) {
                def permuted = permuteVoxelsToASR(reorient.raw_orientation, vx, vy, vz)
                eff_vx = permuted[0]; eff_vy = permuted[1]; eff_vz = permuted[2]
            }

            def aniso_ratio = [eff_vx, eff_vy, eff_vz].max() / [eff_vx, eff_vy, eff_vz].min()
            def ds = (params.bigstitcher.fusion_config.downsample ?: 1) as double
            def fused_x = eff_vx * ds
            def fused_y = eff_vy * ds
            def fused_z = eff_vz * ds

            def lines = []
            lines << ""
            lines << "--- ${name} ---"
            lines << "  Original voxel sizes (CZI):  X=${vx}μm, Y=${vy}μm, Z=${vz}μm"
            lines << "  Original orientation:        ${reorient.raw_orientation.toUpperCase()} (convention: 1st=Z, 2nd=Y, 3rd=X)"
            if (reorient.reorient_to_asr) {
                lines << "  ASR reorientation:           YES (${reorient.raw_orientation.toUpperCase()} → ASR)"
                lines << "  Post-ASR voxel sizes:        X=${eff_vx}μm, Y=${eff_vy}μm, Z=${eff_vz}μm"
            } else {
                lines << "  ASR reorientation:           NO"
            }
            lines << "  Anisotropy ratio:            ${String.format('%.1f', aniso_ratio)}x"
            lines << "  Downsample factor:           ${String.format('%.1f', ds)} (uniform)"
            lines << "  Fused voxel sizes:           X=${String.format('%.1f', fused_x)}μm, Y=${String.format('%.1f', fused_y)}μm, Z=${String.format('%.1f', fused_z)}μm"
            lines.join('\n')
        }
        return
    }

    // Extract original voxel sizes from CZI (runs in parallel with makeCziDatasetForBigstitcher)
    getOriginalVoxelSizes(staged_files, fiji_path)
    def ds = (params.bigstitcher.fusion_config.downsample ?: 1) as double
    original_voxel_sizes = getOriginalVoxelSizes.out.voxel_sizes
        .map { name, x, y, z ->
            def key = PathUtils.getBaseKey(name)
            log.info "Voxel sizes for ${name}: X=${x}μm, Y=${y}μm, Z=${z}μm → uniform downsample=${ds}"
            tuple(key, ds, ds, ds)
        }

    // Makes a bigstitcher xml compatible file from the czi file
    makeCziDatasetForBigstitcher(staged_files, fiji_path)

    // Add keys to both channels for joining
    xml_with_keys = makeCziDatasetForBigstitcher.out
        .map { xml_file ->
            def key = PathUtils.getBaseKey(xml_file.toString())
            tuple(key, xml_file)
        }

    images_with_keys = images
        .map { original_path ->
            def key = PathUtils.getBaseKey(original_path)
            def output_path = params.user_name
                ? "${params.ssh_host}:${params.output_base_path}/${params.user_name}/${key}"
                : null
            tuple(key, original_path, output_path)
        }

    // Join by key (inner join - only matching items)
    xml_not_stitched_with_original_paths = xml_with_keys
        .join(images_with_keys)
        .map { key, xml_file, original_path, output_path ->
            tuple(xml_file, original_path, output_path)
        }

    // Debug: Show the pairing
    xml_not_stitched_with_original_paths.view { xml_file, original_path, output_path ->
        "Will publish ${xml_file.name} to ${output_path ?: 'alongside ' + original_path}"
    }

    // Publish XML files to output locations
    publishInitialXmlToSource(xml_not_stitched_with_original_paths)

    // Channel alignment
    channel_aligned = alignChannelsWithBigstitcher(makeCziDatasetForBigstitcher.out, fiji_path, params.bigstitcher)

    // Tile alignment 
    tile_aligned = alignTilesWithBigstitcher(channel_aligned.aligned_xml, fiji_path, params.bigstitcher)

    // ICP refinement
    icp_refined = icpRefinementWithBigstitcher(tile_aligned.tile_aligned_xml, fiji_path, params.bigstitcher)

    def xml_out

    // Optional ASR Reorientation
    if (params.bigstitcher.reorientation.reorient_to_asr) {
        reoriented_to_asr = reorientToASRWithBigstitcher(icp_refined.icp_refined_xml, fiji_path, params.bigstitcher)
        xml_out = reoriented_to_asr.asr_xml
    } else {
        xml_out = icp_refined.icp_refined_xml
    }

    // Pair XML files with their original input paths for publishing
    xml_out_with_keys = xml_out
        .map { xml_file ->
            def key = PathUtils.getBaseKey(xml_file.toString())
            tuple(key, xml_file)
        }

    // Reuse images_with_keys from earlier (channels can be consumed multiple times)
    xml_with_original_paths = xml_out_with_keys
        .join(images_with_keys)
        .map { key, xml_file, original_path, output_path ->
            tuple(xml_file, original_path, output_path)
        }

    // Debug: Show the pairing
    xml_with_original_paths.view { xml_file, original_path, output_path ->
        "Will publish final xml file ${xml_file.name} to ${output_path ?: 'alongside ' + original_path}"
    }

    // Publish XML files to output locations
    publishStitchedXmlToSource(xml_with_original_paths)

    // Join XML with per-axis downsample factors for fusion
    xml_out_with_ds = xml_out
        .map { xml_file ->
            def key = PathUtils.getBaseKey(xml_file.toString())
            tuple(key, xml_file)
        }
        .join(original_voxel_sizes)
        .map { key, xml_file, ds_x, ds_y, ds_z ->
            tuple(xml_file, ds_x, ds_y, ds_z)
        }

    // Fuse image - always splits by channel, with per-axis downsampling
    fused_images = fuseBigStitcherDataset(
        xml_out_with_ds.map { it[0] },
        fiji_path,
        params.bigstitcher,
        xml_out_with_ds.map { it[1] },
        xml_out_with_ds.map { it[2] },
        xml_out_with_ds.map { it[3] }
    )

    // Publish fused channel TIFFs to analysis output (ch0/, ch1/, etc.)
    if (params.user_name) {
        fused_with_keys = fused_images.named_fused_images
            .map { base_name, channel_files ->
                def key = PathUtils.getBaseKey(base_name)
                tuple(key, base_name, channel_files)
            }

        fused_with_output = fused_with_keys
            .join(images_with_keys)
            .map { key, base_name, channel_files, original_path, output_path ->
                tuple(base_name, channel_files, output_path)
            }

        publishFusedChannelsToSource(fused_with_output)
    }

    // Convert ch1 fused TIFF to OME-Zarr on local cluster storage
    if (params.export_ome_zarr && params.user_name) {
        // Extract ch1 file from fused images and pair with brain key
        ch1_for_zarr = fused_images.named_fused_images
            .map { base_name, channel_files ->
                def file_list = channel_files instanceof List ? new ArrayList(channel_files) : [channel_files]
                def ch1 = file_list.find { it.name.contains('_C1') }
                def key = PathUtils.getBaseKey(base_name)
                return ch1 ? tuple(key, ch1) : null
            }
            .filter { it != null }
            .map { key, ch1_tiff ->
                def zarr_path = "${params.ome_zarr_output_base}/${params.user_name}/${key}/ch1.ome.zarr"
                tuple(key, ch1_tiff, zarr_path)
            }

        ome_zarr_env = omeZarrEnvInstall()
        convertTiffToOmeZarr(ome_zarr_env, ch1_for_zarr)
        publishOmeZarr(convertTiffToOmeZarr.out.zarr_result)

        // Spotiflow spot detection on Kuma (GPU), automatically after the
        // OME-Zarr is published to the shared /work filesystem.
        if (params.run_spotiflow) {
            spotiflow_input = publishOmeZarr.out.published
                .map { key, zarr ->
                    def out_dir = "${params.ome_zarr_output_base}/${params.user_name}/detection_results/${params.spotiflow_version}/${key}"
                    tuple(key, zarr, out_dir)
                }
            spotiflowDetectKuma(spotiflow_input)
        }
    }

    // Stop here if fusion_only mode
    if (params.fusion_only) {
        log.info "========================================="
        log.info "  FUSION ONLY - Skipping brainreg"
        log.info "========================================="
        return
    }

    // Process each image completely through the brainreg preparation pipeline
    image_processing = fused_images.named_fused_images
        .map { base_name, channel_files ->
            // Get first channel for voxel size detection
            def file_list = channel_files instanceof List ? channel_files : [channel_files]
            def sorted_files = file_list.sort { it.name }
            def first_channel = sorted_files[0]
            
            // Return tuple with all info needed for this image
            return tuple(base_name, channel_files, first_channel)
        }
    
    // Debug: Show what we're processing
    image_processing.view { base_name, channel_files, first_channel ->
        "Processing image: ${base_name} with ${channel_files.size()} channels, using ${first_channel.name} for voxel sizes"
    }
    
    // Get voxel sizes for each image
    voxel_results = getVoxelSizes(
        image_processing.map { base_name, channel_files, first_channel -> first_channel },
        fiji_path
    )

    // brainreg env is needed by organizeChannelsForBrainreg (uses tifffile to
    // pre-split each channel into a directory of 2D slices, which lets brainreg
    // dispatch to its parallel slice-wise loader).
    brainreg_install = brainregEnvInstall()
    atlas_cache = downloadAtlas(brainreg_install, params.brainreg.atlas)

    // Organize channels for brainreg for each image
    organized_channels = organizeChannelsForBrainreg(
        image_processing.map { base_name, channel_files, first_channel -> tuple(base_name, channel_files) },
        params.brainreg.channel_used_for_registration,
        brainreg_install
    )

    // Combine everything for brainreg input using explicit key-based join
    organized_with_keys = organized_channels.organized_channels
        .map { primary, additional, base_name, primary_basename ->
            def key = PathUtils.getBaseKey(base_name)
            tuple(key, primary, additional, base_name, primary_basename)
        }

    voxel_with_keys = voxel_results.voxel_sizes
        .map { voxel_name, x, y, z ->
            def key = PathUtils.getBaseKey(voxel_name)
            tuple(key, x, y, z)
        }

    brainreg_input = organized_with_keys
        .join(voxel_with_keys)
        .map { key, primary, additional, base_name, primary_basename, x, y, z ->
            tuple(primary, additional, base_name, primary_basename, x, y, z)
        }
    
    // Debug: View what will be processed
    brainreg_input.view { primary, additional, name, primary_basename, x, y, z ->
        "Ready for brainreg: ${name} (primary=${primary_basename}) with voxel sizes: X=${x}μm, Y=${y}μm, Z=${z}μm"
    }

    // CREATE PARAMETER SWEEP COMBINATIONS using Nextflow channels
    bending_energy_ch = Channel.fromList(ensureList(params.brainreg.bending_energy_weight))
    grid_spacing_ch = Channel.fromList(ensureList(params.brainreg.grid_spacing))
    smoothing_sigma_ch = Channel.fromList(ensureList(params.brainreg.smoothing_sigma_floating))
    
    // Combine all parameter channels to create all combinations NOTE: it's a nextflow channel, not an image channel!
    param_combinations = bending_energy_ch
        .combine(grid_spacing_ch)
        .combine(smoothing_sigma_ch)
        .map { bending, grid, sigma -> 
            [
                bending_energy_weight: bending,
                grid_spacing: grid,
                smoothing_sigma_floating: sigma
            ]
        }
    
    // Log the parameter combinations that will be tested
    param_combinations.view { combo ->
        "Parameter combination: bending_energy_weight=${combo.bending_energy_weight}, grid_spacing=${combo.grid_spacing}, smoothing_sigma_floating=${combo.smoothing_sigma_floating}"
    }
    
    // Cross brainreg input with parameter combinations
    brainreg_sweep_input = brainreg_input.combine(param_combinations)

    // Run brainreg with primary and additional channels
    // (brainreg_install and atlas_cache were created above so organize step
    // could share the same env)
    brr = brainregRunRegistration(brainreg_install,
                           atlas_cache,
                           brainreg_sweep_input,
                           params)

    // Process the first channel: extract the first element of each tuple
    def processed_results = brr.named_results.map { it ->
        def key = PathUtils.getBaseKey(it[0])
        tuple(key, it[1], it[2])
    }

    // Construct output paths for each brain using images_with_keys (which carries output_path)
    def processed_images = images_with_keys.map { key, original_path, output_path ->
        tuple(key, original_path, output_path)
    }

    // Combine the channels by the key to get all combinations
    result_and_paths = processed_results
        .combine(processed_images, by: 0)
        .map { key, combo, result_files, original_path, output_path ->
            tuple(key, output_path, combo, result_files, original_path)
        }

    copyResultsToImageFolder(result_and_paths)

}

// OME-Zarr-only entry point: skip stitching/fusion/brainreg entirely and convert
// already-fused ch1 TIFFs (published under <output_base_path>/<user_name>/<key>/ch1/)
// straight to OME-Zarr on local cluster storage.
//
// Usage:
//   nextflow run main.nf -entry omeZarrOnly -profile slurm \
//       --brain_id MS190,MS191,MS192 --user_name First_Last
workflow omeZarrOnly {
    if (!params.brain_id) {
        error "omeZarrOnly requires --brain_id (comma-separated, e.g. --brain_id MS190,MS191)"
    }
    if (!params.user_name) {
        error "omeZarrOnly requires --user_name (e.g. --user_name First_Last)"
    }

    def keys = params.brain_id.split(',').collect { it.trim() }
    log.info "OME-Zarr-only conversion for: ${keys.join(', ')} (user: ${params.user_name})"

    // Stage the already-fused ch1 TIFF for each brain from the remote analysis tree
    stage_inputs = Channel.fromList(keys).map { key ->
        def remote_ch1_dir = "${params.output_base_path}/${params.user_name}/${key}/ch1"
        tuple(key, params.ssh_host, remote_ch1_dir)
    }
    staged = stageFusedCh1(stage_inputs)

    // Pair each staged TIFF with its target zarr path
    convert_inputs = staged.staged.map { key, ch1_tiff ->
        def zarr_path = "${params.ome_zarr_output_base}/${params.user_name}/${key}/ch1.ome.zarr"
        tuple(key, ch1_tiff, zarr_path)
    }

    ome_zarr_env = omeZarrEnvInstall()
    convertTiffToOmeZarr(ome_zarr_env, convert_inputs)
    publishOmeZarr(convertTiffToOmeZarr.out.zarr_result)
}