#!/usr/bin/env nextflow

process brainregEnvInstall {
    container 'python:3.11'
    cache 'lenient'
    storeDir params.env_cache_dir
    
    output:
    path "brainreg_env"
    
    script:
    """
    # Ensure pip is available
    python3 -m ensurepip --upgrade
    python3 -m pip install --target brainreg_env brainreg==1.0.13 tables==3.10.2 imagecodecs
    echo "Installation complete"
    """
}

process brainregTestEnv {
    container 'python:3.11'
   
    input:
    path brainreg_env
   
    output:
    path "results.txt"
   
    script:
    """
    # Add the shared directory to Python path (handle unset PYTHONPATH)
    export PYTHONPATH=\${PWD}/${brainreg_env}:\${PYTHONPATH:-}

    python -c "
    import sys
    import brainreg
    import tables

    print('✓ Using shared installation!')
    print('Python version:', sys.version.split()[0])
    print('Brainreg version:', getattr(brainreg, '__version__', 'unknown'))
    print('Tables version:', getattr(tables, '__version__', 'unknown'))
    " > results.txt
    """
}

process organizeChannelsForBrainreg {
    container 'python:3.11'
    tag "organize ${base_name}"
    // publishDir "${params.outdir}/brainreg_ready", mode: 'copy'

    input:
    tuple val(base_name), path(channel_files)
    val registration_channel
    path brainreg_env

    output:
    tuple path("primary"), path("additional_channels.txt"), val(base_name), env('PRIMARY_BASENAME'), emit: organized_channels

    script:
    """
    # brainreg_env carries tifffile (transitive dep of brainreg)
    export PYTHONPATH=\${PWD}/${brainreg_env}:\${PYTHONPATH:-}

    # Sort channel files to ensure consistent ordering
    SORTED_FILES=\$(ls ${channel_files} | sort -V)
    echo "Found channels:"
    echo "\${SORTED_FILES}"

    # Count channels
    CHANNEL_COUNT=\$(echo "\${SORTED_FILES}" | wc -l)
    echo "Total channels: \${CHANNEL_COUNT}"

    # Extract the primary channel (0-indexed)
    PRIMARY_CHANNEL=\$(echo "\${SORTED_FILES}" | sed -n "\$((${registration_channel} + 1))p")
    echo "Primary channel for registration: \${PRIMARY_CHANNEL}"

    # Capture primary basename so brainregRunRegistration can name its outputs
    # after the original channel file (the primary input is now a directory).
    export PRIMARY_BASENAME=\$(basename "\${PRIMARY_CHANNEL}" .tiff)
    echo "Primary basename: \${PRIMARY_BASENAME}"

    # Split primary channel into per-slice TIFFs. brainreg's slice-wise loader
    # path parallelizes the gaussian-filter + downsample step across slices,
    # which is ~3x faster and ~3x lower memory than the single 3D loader.
    python3 ${projectDir}/bin/split_tiff_to_slices.py "\${PRIMARY_CHANNEL}" "primary"

    # Split each additional channel into its own slice directory and record
    # the directory paths (brainreg --additional accepts directories).
    > additional_channels.txt
    CHANNEL_INDEX=0
    for CHANNEL in \${SORTED_FILES}; do
        if [ \${CHANNEL_INDEX} -ne ${registration_channel} ]; then
            CHANNEL_BASE=\$(basename "\${CHANNEL}" .tiff)
            python3 ${projectDir}/bin/split_tiff_to_slices.py "\${CHANNEL}" "\${CHANNEL_BASE}"
            echo "\$(pwd)/\${CHANNEL_BASE}" >> additional_channels.txt
        fi
        CHANNEL_INDEX=\$((CHANNEL_INDEX + 1))
    done

    echo "Additional channel directories:"
    cat additional_channels.txt
    """
}
process brainregRunRegistration {
    container 'python:3.11'
    // Updated tag to include parameter combination info
    tag "brainreg_${image_name}_bending${param_combo.bending_energy_weight}_grid${param_combo.grid_spacing}_sigma${param_combo.smoothing_sigma_floating}"
    
    // Updated publishDir to organize outputs by parameter combination
    // publishDir "${params.outdir}/brainreg_output/${image_name}_bending${param_combo.bending_energy_weight}_grid${param_combo.grid_spacing}_sigma${param_combo.smoothing_sigma_floating}", mode: 'copy'
    
    input:
    path brainreg_env
    path atlas_cache
    tuple path(primary_channel), path(additional_channels_file), val(image_name), val(primary_basename), val(voxel_x), val(voxel_y), val(voxel_z), val(param_combo)
    val config
    
    output:
    path "brainreg_output/*", emit: registered_brain
    path "brainreg_log.txt", emit: log
    tuple val(image_name), val(param_combo), path("brainreg_output/*"), emit: named_results

    script:
    params_brainreg = config.brainreg
    
    def orientation
    if (!config.bigstitcher.reorientation.reorient_to_asr) {
        orientation = config.bigstitcher.reorientation.raw_orientation.toLowerCase()
    } else {
        orientation = "asr"
    }
    
    // Read additional channels from file
    def additional_channels_args = ""
    if (additional_channels_file.name != "NO_FILE") {
        additional_channels_args = "--additional \$(cat ${additional_channels_file} | tr '\\n' ' ')"
    }
    
    """
    # Add the shared directory to Python path
    export PYTHONPATH=\${PWD}/${brainreg_env}:\${PYTHONPATH:-}
    export PATH=\${PWD}/${brainreg_env}/bin:\${PATH}

    # Point brainglobe at the shared atlas cache.
    # BRAINGLOBE_CONFIG_DIR is the env var brainglobe-atlasapi actually reads
    # (see brainglobe_atlasapi/config.py). The cache must contain a bg_config.conf
    # whose brainglobe_dir points back to the cache itself.
    export BRAINGLOBE_CONFIG_DIR=\${PWD}/${atlas_cache}
    export HOME=\${PWD}
    
    echo "Processing image: ${image_name}"
    echo "Parameter combination:"
    echo "  bending_energy_weight: ${param_combo.bending_energy_weight}"
    echo "  grid_spacing: ${param_combo.grid_spacing}"
    echo "  smoothing_sigma_floating: ${param_combo.smoothing_sigma_floating}"
    echo "Primary channel: ${primary_channel}"
    echo "Additional channels:"
    if [ -f "${additional_channels_file}" ]; then
        cat "${additional_channels_file}"
    fi
    
    # Create output directory
    mkdir -p brainreg_output
    
    # Build the brainreg command
    BRAINREG_CMD="brainreg \\
        ${primary_channel} \\
        brainreg_output \\
        --atlas ${params_brainreg.atlas} \\
        --backend ${params_brainreg.backend} \\
        --affine-n-steps ${params_brainreg.affine_n_steps} \\
        --affine-use-n-steps ${params_brainreg.affine_use_n_steps} \\
        --freeform-n-steps ${params_brainreg.freeform_n_steps} \\
        --freeform-use-n-steps ${params_brainreg.freeform_use_n_steps} \\
        --bending-energy-weight ${param_combo.bending_energy_weight} \\
        --grid-spacing ${param_combo.grid_spacing} \\
        --smoothing-sigma-reference ${params_brainreg.smoothing_sigma_reference} \\
        --smoothing-sigma-floating ${param_combo.smoothing_sigma_floating} \\
        --histogram-n-bins-floating ${params_brainreg.histogram_n_bins_floating} \\
        --histogram-n-bins-reference ${params_brainreg.histogram_n_bins_reference} \\
        -v ${voxel_z} ${voxel_y} ${voxel_x} \\
        --n-free-cpus ${params_brainreg.n_free_cpus} \\
        ${params_brainreg.debug ? '--debug' : ''} \\
        --orientation ${orientation} \\
        ${params_brainreg.save_original_orientation ? '--save-original-orientation' : ''} \\
        --brain_geometry ${params_brainreg.brain_geometry} \\
        ${params_brainreg.sort_input_file ? '--sort-input-file' : ''} \\
        --pre-processing ${params_brainreg.pre_processing}"
    
    # Add additional channels if they exist
    if [ -f "${additional_channels_file}" ] && [ -s "${additional_channels_file}" ]; then
        echo "Adding additional channels to brainreg command"
        BRAINREG_CMD="\${BRAINREG_CMD} ${additional_channels_args}"
    fi
    
    echo "Full brainreg command:"
    echo "\${BRAINREG_CMD}"
    
    # Run brainreg (pipefail ensures a killed/crashed brainreg propagates exit code through tee)
    set -o pipefail
    eval "\${BRAINREG_CMD}" 2>&1 | tee brainreg_log.txt

    # Verify brainreg produced actual registration output
    if [ ! -f "brainreg_output/registered_atlas.tiff" ]; then
        echo "ERROR: brainreg completed but registered_atlas.tiff is missing - registration likely failed (OOM?)"
        exit 1
    fi

    # Rename primary channel outputs to include the original filename,
    # matching the pattern brainreg uses for additional channels.
    # primary_basename is captured upstream because the primary input is now
    # a directory of slices, so basename(primary_channel) would yield "primary".
    for prefix in downsampled downsampled_standard; do
        if [ -f "brainreg_output/\${prefix}.tiff" ]; then
            mv "brainreg_output/\${prefix}.tiff" "brainreg_output/\${prefix}_${primary_basename}.tiff"
            echo "Renamed \${prefix}.tiff to \${prefix}_${primary_basename}.tiff"
        fi
    done

    echo "Brainreg processing completed for parameter combination:"
    echo "  bending_energy_weight: ${param_combo.bending_energy_weight}"
    echo "  grid_spacing: ${param_combo.grid_spacing}"
    echo "  smoothing_sigma_floating: ${param_combo.smoothing_sigma_floating}"
    ls -la brainreg_output/
    """
}

process downloadAtlas {
    container 'python:3.11'
    storeDir params.atlas_cache_dir
    
    input:
    path brainreg_env
    val atlas_name
    
    output:
    path "brainglobe_cache", emit: atlas_cache
    
    script:
    """
    export PYTHONPATH=\${PWD}/${brainreg_env}:\${PYTHONPATH:-}
    export PATH=\${PWD}/${brainreg_env}/bin:\${PATH}
    
    # Create cache directory
    mkdir -p brainglobe_cache

    # Seed bg_config.conf so brainglobe stores atlases in the cache directory
    # rather than the default HOME/.brainglobe. brainglobe-atlasapi reads
    # bg_config.conf from BRAINGLOBE_CONFIG_DIR (config.py).
    if [ ! -f brainglobe_cache/bg_config.conf ]; then
        CACHE_ABS=\$(readlink -f brainglobe_cache)
        printf '[default_dirs]\\nbrainglobe_dir = %s\\ninterm_download_dir = %s\\n' "\$CACHE_ABS" "\$CACHE_ABS" > brainglobe_cache/bg_config.conf
    fi

    export BRAINGLOBE_CONFIG_DIR=\${PWD}/brainglobe_cache
    export HOME=\${PWD}

    # Download atlas
    python -c "
from brainglobe_atlasapi.bg_atlas import BrainGlobeAtlas
atlas = BrainGlobeAtlas('${atlas_name}')
print(f'Atlas ${atlas_name} downloaded and cached successfully')
"
    """
}
