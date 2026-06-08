#!/usr/bin/env nextflow

/*
 * Spotiflow spot detection — runs on the Kuma GPU cluster (h100), orchestrated
 * from the Jed-side Nextflow run.
 *
 * Nextflow's slurm executor can only talk to Jed's scheduler, so this process
 * runs on the Jed login node (executor = local), submits an sbatch job to Kuma
 * over SSH, and blocks until that job finishes. Input/output live on /work,
 * which is shared between Jed and Kuma, so no data is copied across clusters.
 *
 * Requirements (verified at setup):
 *   - passwordless SSH Jed -> ${params.kuma_host}
 *   - /work shared between clusters
 *   - model + sbatch script on the shared /home, spotiflow env on Kuma
 */
process spotiflowDetectKuma {
    tag "spotiflow ${brain_key} (kuma)"

    input:
    tuple val(brain_key), val(zarr_path), val(out_dir)

    output:
    tuple val(brain_key), val(out_dir), emit: detections

    script:
    """
    # NOTE: Nextflow runs this with `bash -ue`. We deliberately do NOT enable
    # `pipefail` — a benign SIGPIPE from `head` closing a pipe early would
    # otherwise abort the script. ssh uses `-n` so it never reads the task's
    # stdin (scripted ssh without -n can consume stdin and break). All errors
    # are handled explicitly so the task fails loudly with diagnostics.
    KUMA='${params.kuma_host}'
    ZARR='${zarr_path}'
    OUTDIR='${out_dir}'
    MODEL='${params.models_dir}/${params.spotiflow_model}'
    SBATCH='${params.spotiflow_sbatch}'
    SSH="ssh -n -o BatchMode=yes -o ConnectTimeout=30"

    echo "Submitting spotiflow for ${brain_key} on Kuma (\$KUMA)"
    echo "  input : \$ZARR"
    echo "  output: \$OUTDIR"

    # When many brains submit at once they hit Kuma's sshd rate limit
    # (MaxStartups -> "kex_exchange_identification: Connection closed"). Stagger
    # the initial burst and retry submission with backoff + jitter so transient
    # ssh rejections don't fail the task. sbatch_spotiflow.batch runs
    # `spotiflow-predict \$@`; the --parsable job id is the only all-digits line.
    sleep \$((RANDOM % 20))
    JOBID=""
    for attempt in 1 2 3 4 5 6 7 8; do
        SUBMIT_OUT=\$(\$SSH "\$KUMA" "mkdir -p '\$OUTDIR' && SPOTIFLOW_ENV='${params.env_cache_dir}/spotiflow_12' sbatch --parsable '\$SBATCH' '\$ZARR' --verbose --out-dir '\$OUTDIR' -md '\$MODEL' --max-tile-size 256 256 256 --zarr-component 0 --zarr-component-lowres 3" 2>&1) || true
        JOBID=\$(printf '%s\\n' "\$SUBMIT_OUT" | grep -oE '^[0-9]+\$' | head -1 || true)
        if [ -n "\$JOBID" ]; then break; fi
        echo "submit attempt \$attempt failed; output:"; printf '%s\\n' "\$SUBMIT_OUT"
        sleep \$((attempt * 15 + RANDOM % 15))
    done
    if [ -z "\$JOBID" ]; then echo "ERROR: failed to submit spotiflow job on Kuma after retries"; exit 1; fi
    echo "Kuma job id: \$JOBID"

    # Poll until the job leaves the queue. Only conclude "done" when SSH
    # succeeded AND squeue returned nothing (transient ssh failures retry).
    while true; do
        STATE=\$(\$SSH "\$KUMA" "squeue -h -j \$JOBID -o %T" 2>/dev/null || echo __SSHFAIL__)
        if [ "\$STATE" = "__SSHFAIL__" ]; then echo "  [\$(date +%H:%M:%S)] ssh poll failed; retrying"; sleep 120; continue; fi
        [ -z "\$STATE" ] && break
        echo "  [\$(date +%H:%M:%S)] job \$JOBID: \$STATE"
        sleep 120
    done

    # Confirm it actually completed (not FAILED/TIMEOUT/CANCELLED).
    FINAL=\$(\$SSH "\$KUMA" "sacct -j \$JOBID -n -X -o State" 2>/dev/null | head -1 | tr -d ' ' || true)
    echo "Kuma job \$JOBID final state: \$FINAL"
    if [ "\$FINAL" != "COMPLETED" ]; then
        echo "ERROR: spotiflow job \$JOBID ended as '\$FINAL' (logs on Kuma: ~/logs/\$JOBID.out and .err)"
        exit 1
    fi
    echo "spotiflow predictions written to \$OUTDIR"
    """
}
