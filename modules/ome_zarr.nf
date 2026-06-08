process omeZarrEnvInstall {
    container 'python:3.11'
    cache 'lenient'
    storeDir params.env_cache_dir

    output:
    path "ome_zarr_env"

    script:
    """
    python3 -m ensurepip --upgrade
    python3 -m pip install --target ome_zarr_env iohub tifffile scikit-image numpy tqdm imagecodecs
    echo "OME-Zarr environment installation complete"
    """
}

process stageFusedCh1 {
    tag "stage fused ch1 ${brain_key}"

    input:
    tuple val(brain_key), val(ssh_host), val(remote_ch1_dir)

    output:
    tuple val(brain_key), path("${brain_key}_C1.tiff"), emit: staged

    script:
    """
    set -euo pipefail
    # The fused filename suffix varies with the bigstitcher steps that ran,
    # so resolve the actual *_C1.tiff on the remote rather than hardcoding it.
    remote_file=\$(ssh ${ssh_host} "ls -1 ${remote_ch1_dir}/*_C1.tiff 2>/dev/null | head -1")
    if [ -z "\$remote_file" ]; then
        echo "ERROR: no *_C1.tiff found in ${ssh_host}:${remote_ch1_dir}"
        exit 1
    fi
    echo "Staging \$remote_file -> ${brain_key}_C1.tiff"
    rsync -avz --progress "${ssh_host}:\$remote_file" "${brain_key}_C1.tiff"
    test -s "${brain_key}_C1.tiff"
    """
}

process convertTiffToOmeZarr {
    container 'python:3.11'
    tag "ome_zarr_${brain_key}"

    input:
    path ome_zarr_env
    tuple val(brain_key), path(ch1_tiff), val(zarr_output_path)

    output:
    tuple val(brain_key), path("ch1.ome.zarr"), val(zarr_output_path), emit: zarr_result

    script:
    """
    export PYTHONPATH=\${PWD}/${ome_zarr_env}:\${PYTHONPATH:-}

    # Copy conversion script to work directory
    cp ${projectDir}/bin/tiff_to_ome_zarr.py .

    echo "Converting ${ch1_tiff} to OME-Zarr"

    # Write zarr to local work directory (container can't write to /work/lsens)
    python3 tiff_to_ome_zarr.py \\
        --input "${ch1_tiff}" \\
        --output "ch1.ome.zarr" \\
        --channel-name ch1 \\
        --levels 6
    """
}

process publishOmeZarr {
    tag "publish ome_zarr ${brain_key}"

    input:
    tuple val(brain_key), path(zarr_dir), val(zarr_output_path)

    output:
    path "publish_log.txt", emit: log
    tuple val(brain_key), val(zarr_output_path), emit: published

    script:
    """
    set -euo pipefail
    echo "Publishing ${zarr_dir} to ${zarr_output_path}" | tee publish_log.txt

    # The staged input is a symlink into the (scratch) work dir. Verify its
    # target actually contains data before publishing, so a purged/empty
    # source fails loudly instead of silently publishing an empty directory.
    if [ ! -e "${zarr_dir}/0" ]; then
        echo "ERROR: source zarr ${zarr_dir} has no array '0' (empty or missing)" | tee -a publish_log.txt
        exit 1
    fi

    # Remove any stale/partial destination from a previous failed run
    rm -rf "${zarr_output_path}"

    # Create target parent directory
    mkdir -p \$(dirname "${zarr_output_path}")

    # Copy zarr directory to final location.
    # -L dereferences the staged symlink so the real data is copied (a plain
    # `cp -r` copies the symlink, not its contents).
    cp -rL "${zarr_dir}" "${zarr_output_path}"

    # Verify the published copy actually contains the array
    if [ ! -e "${zarr_output_path}/0" ]; then
        echo "ERROR: published zarr ${zarr_output_path} has no array '0' after copy" | tee -a publish_log.txt
        exit 1
    fi

    echo "Successfully published OME-Zarr to ${zarr_output_path}" | tee -a publish_log.txt
    echo "Completed at: \$(date)" >> publish_log.txt
    """
}
