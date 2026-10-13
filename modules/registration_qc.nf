#!/usr/bin/env nextflow

/*
 * Registration selection and points-to-atlas.
 *
 * After the brainreg parameter sweep, every variant of a brain is scored in
 * brain space (bin/registration_scoring.py), the best one is chosen and given a
 * verdict, and two QC figures are drawn (bin/registration_select.py). The
 * spotiflow detections are then pushed into atlas space through the chosen
 * registration (bin/points_to_atlas.py) - always, whatever the verdict; the
 * verdict travels with the points in registration_choice.json.
 */

process regQcEnvInstall {
    container 'python:3.11'
    cache 'lenient'
    storeDir params.env_cache_dir

    output:
    path "regqc_env"

    script:
    """
    python3 -m ensurepip --upgrade
    python3 -m pip install --target regqc_env numpy scipy pandas tifffile imagecodecs matplotlib
    echo "Installation complete"
    """
}

process selectBestRegistration {
    container 'python:3.11'
    tag "select registration ${key}"
    publishDir path: "${params.ome_zarr_output_base}/${params.user_name}/${key}",
               mode: 'copy', enabled: params.user_name != null

    input:
    path regqc_env
    path atlas_cache
    tuple val(key), val(variant_names), path(variant_dirs, stageAs: 'variant_??')

    output:
    tuple val(key), env(SELECTED), path("registration_qc/evaluation.json"), emit: selected
    tuple val(key), path("registration_qc"), emit: qc

    script:
    def dirs = variant_dirs instanceof List ? variant_dirs : [variant_dirs]
    def variant_args = [variant_names, dirs].transpose()
        .collect { name, dir -> "--variant '${name}=${dir}'" }.join(' ')
    def qc = params.registration_qc
    """
    export PYTHONPATH=\${PWD}/${regqc_env}:\${PYTHONPATH:-}
    export HOME=\${PWD} MPLCONFIGDIR=\${PWD}/.mpl OPENBLAS_NUM_THREADS=1

    ATLAS_DIR=\$(ls -d ${atlas_cache}/${params.brainreg.atlas}_v* | sort -V | tail -1)
    echo "Atlas: \${ATLAS_DIR}"

    python3 ${projectDir}/bin/registration_select.py \\
        --brain ${key} \\
        --atlas-dir "\${ATLAS_DIR}" \\
        ${variant_args} \\
        --out registration_qc \\
        --display-channel ${qc.display_channel} \\
        --tau ${qc.tau} \\
        --prior-median ${qc.prior_median} \\
        --prior-mad ${qc.prior_mad} \\
        --catastrophic-dice ${qc.catastrophic_dice} \\
        --flat-spread ${qc.flat_spread} \\
        --distortion-prior-median ${qc.distortion_prior_median} \\
        --mask-clip-max ${qc.mask_clip_max}

    SELECTED=\$(cat registration_qc/selected.txt)
    """
}

process transformPointsToAtlas {
    container 'python:3.11'
    tag "points to atlas ${key}"
    publishDir path: "${det_dir}", mode: 'copy', saveAs: { fn -> fn.tokenize('/')[-1] }

    input:
    path brainreg_env
    path atlas_cache
    tuple val(key), val(variant_name), path(registration, stageAs: 'selected_registration'),
          path(evaluation_json), path(ch1_csv), path(zarr_meta, stageAs: 'zarr_level0.json'),
          val(det_dir)

    output:
    tuple val(key), path("points/*"), emit: points

    script:
    """
    export PYTHONPATH=\${PWD}/${brainreg_env}:\${PYTHONPATH:-}
    export BRAINGLOBE_CONFIG_DIR=\${PWD}/${atlas_cache}
    export HOME=\${PWD} OPENBLAS_NUM_THREADS=1

    python3 -u ${projectDir}/bin/points_to_atlas.py \\
        --detections ${ch1_csv} \\
        --registration ${registration} \\
        --registration-name '${variant_name}' \\
        --zarr ${zarr_meta} \\
        --evaluation ${evaluation_json} \\
        --out points
    """
}

/*
 * Copies files or folders into <output_path>/<subdir>/ on the NAS. Included
 * twice in main.nf: for registration_qc/ and for the detection results.
 */
process publishFilesToSource {
    tag "publish ${subdir} for ${key}"

    input:
    tuple val(key), path(items), val(output_path), val(subdir)

    script:
    def targetInfo = PathUtils.parseOutputPath(output_path)
    def targetDir = "${targetInfo.remotePath}/${subdir}"
    """
    # The destination is a CIFS/SMB share; retry mkdir and each rsync with
    # backoff so a transient I/O error doesn't fail the task.
    for attempt in 1 2 3; do
        if ssh ${targetInfo.sshHost} "mkdir -p '${targetDir}'"; then break; fi
        if [ \$attempt -eq 3 ]; then echo "ERROR: mkdir failed after 3 attempts"; exit 1; fi
        sleep \$((attempt * 2))
    done

    for item in ${items}; do
        success=0
        for attempt in 1 2 3 4 5; do
            if rsync -rltvL --inplace --no-perms --no-owner --no-group --no-times --modify-window=1 \\
                "\$item" "${targetInfo.sshHost}:${targetDir}/"; then
                success=1
                break
            fi
            backoff=\$((2 ** attempt))
            echo "rsync of \$item failed on attempt \$attempt; retrying in \${backoff}s..."
            sleep \$backoff
        done
        if [ \$success -ne 1 ]; then echo "ERROR: rsync of \$item failed after 5 attempts"; exit 1; fi
    done

    echo "Published to ${targetInfo.sshHost}:${targetDir}/"
    """
}
