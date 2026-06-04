process stageFiles {
    tag "stage_${file(input_file).name}"
    
    input:
    path input_file
    
    output:
    path "${file(input_file).name}", emit: staged_file
    
    script:
    """
    # Nextflow automatically stages the input file to the work directory
    # We can use rsync for a robust copy with verification
    
    echo "Staging file: ${input_file}"
    echo "Current directory: \$(pwd)"
    echo "File size: \$(stat -c%s "${input_file}" 2>/dev/null || stat -f%z "${input_file}" 2>/dev/null) bytes"
    
    # The file is already staged by Nextflow, but we can verify it
    if [ -f "${file(input_file).name}" ]; then
        echo "File successfully staged: ${file(input_file).name}"
        
        # Optional: Calculate checksum for verification
        if command -v md5sum &> /dev/null; then
            MD5_CHECKSUM=\$(md5sum "${file(input_file).name}" | cut -d' ' -f1)
            echo "MD5 checksum: \$MD5_CHECKSUM"
        fi
    else
        echo "ERROR: Staged file not found!"
        exit 1
    fi
    """
}

process stageFilesRSync {
    tag "stageRSync_${file(input_file).name}"
    
    // Disable Nextflow's automatic staging
    stageInMode 'copy'
    
    input:
    path input_file
    
    output:
    path "${file(input_file).name}", emit: staged_file
    
    script:
    """
    # Use rsync for robust file transfer with verification
    echo "Staging file with rsync: ${input_file}"
    echo "Source path: ${input_file}"
    echo "Target: \$(pwd)/${file(input_file).name}"
    
    # Set rsync options for robust transfer
    RSYNC_OPTS="--archive"           # Preserve permissions, timestamps, etc.
    # RSYNC_OPTS="\$RSYNC_OPTS --checksum"      # Verify with checksums, not just size/time
    RSYNC_OPTS="\$RSYNC_OPTS --partial"       # Keep partial transfers for resume
    RSYNC_OPTS="\$RSYNC_OPTS --progress"      # Show progress
    RSYNC_OPTS="\$RSYNC_OPTS --compress"      # Compress during transfer (good for CZI)
    
    # Number of retry attempts
    MAX_RETRIES=3
    RETRY_COUNT=0
    
    # Transfer with retry logic
    while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
        echo "Transfer attempt \$((RETRY_COUNT + 1)) of \$MAX_RETRIES"
        
        if rsync \${RSYNC_OPTS} "${input_file}" "./"; then
            echo "Successfully transferred via rsync"
            break
        else
            RETRY_COUNT=\$((RETRY_COUNT + 1))
            if [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; then
                echo "Transfer failed, retrying in 5 seconds..."
                sleep 5
            else
                echo "ERROR: Failed to transfer after \$MAX_RETRIES attempts"
                exit 1
            fi
        fi
    done
    
    # Verify the transferred file
    if [ -f "${file(input_file).name}" ]; then
        # Get file sizes for verification
        ORIGINAL_SIZE=\$(stat -c%s "${input_file}" 2>/dev/null || stat -f%z "${input_file}" 2>/dev/null)
        TRANSFERRED_SIZE=\$(stat -c%s "${file(input_file).name}" 2>/dev/null || stat -f%z "${file(input_file).name}" 2>/dev/null)
        
        echo "Original size: \$ORIGINAL_SIZE bytes"
        echo "Transferred size: \$TRANSFERRED_SIZE bytes"
        
        if [ "\$ORIGINAL_SIZE" = "\$TRANSFERRED_SIZE" ]; then
            echo "File size verification: PASSED"
        else
            echo "ERROR: File size mismatch!"
            exit 1
        fi
        
        # Calculate checksums for extra verification
        # if command -v md5sum &> /dev/null; then
        #    echo "Calculating MD5 checksums..."
        #    ORIGINAL_MD5=\$(md5sum "${input_file}" | cut -d' ' -f1)
        #    TRANSFERRED_MD5=\$(md5sum "${file(input_file).name}" | cut -d' ' -f1)
        #    
        #    echo "Original MD5: \$ORIGINAL_MD5"
        #    echo "Transferred MD5: \$TRANSFERRED_MD5"
        #    
        #    if [ "\$ORIGINAL_MD5" = "\$TRANSFERRED_MD5" ]; then
        #        echo "MD5 verification: PASSED"
        #    else
        #        echo "ERROR: MD5 checksum mismatch!"
        #        exit 1
        #    fi
        # fi
    else
        echo "ERROR: Transferred file not found!"
        exit 1
    fi
    
    echo "File staging completed successfully"
    """
}

process copyResultsToImageFolder {
    tag "${key}_${combo.collect { k, v -> "${k}${v}" }.join('_')}" // Optional: for logging/identification
    maxForks 1  // serialize haas<->cluster transfers to avoid bandwidth/disk contention

    input:
    tuple val(key), val(output_path), val(combo), path(output_files), val(original_path)

    // No Output

    script:
    // Construct the target subfolder name from the parameters
    def paramsString = combo.collect { k, v -> "${k}${v}" }.join('_')

    // Use output_path (analysis tree) if available, otherwise fall back to input location
    def targetInfo
    def targetDir
    if (output_path) {
        targetInfo = PathUtils.parseOutputPath(output_path)
        targetDir = "${targetInfo.remotePath}/registration/${key}_${paramsString}"
    } else {
        def sshInfo = PathUtils.parseSshPath(original_path)
        targetInfo = [sshHost: sshInfo.sshHost]
        targetDir = "${sshInfo.remoteDir}/${sshInfo.basename}_${paramsString}"
    }

    """
    echo "Create the target directory via SSH: ${targetInfo.sshHost}:${targetDir}"
    # The destination is a CIFS/SMB share mounted with soft,retrans=1 -- any
    # transient network blip surfaces as EIO/EHOSTDOWN. Retry mkdir and each
    # rsync with backoff so a single blip doesn't fail the whole task.
    for attempt in 1 2 3; do
        if ssh ${targetInfo.sshHost} "mkdir -p ${targetDir}"; then
            break
        fi
        if [ \$attempt -eq 3 ]; then
            echo "ERROR: mkdir failed after 3 attempts"
            exit 1
        fi
        echo "mkdir attempt \$attempt failed; retrying in \$((attempt * 2))s..."
        sleep \$((attempt * 2))
    done

    # Copy each file individually with SMB-friendly flags to remote server
    for file in ${output_files}; do
        success=0
        for attempt in 1 2 3 4 5; do
            if rsync -rltvL --progress --inplace --no-perms --no-owner --no-group --no-times --modify-window=1 "\$file" "${targetInfo.sshHost}:${targetDir}/"; then
                success=1
                break
            fi
            backoff=\$((2 ** attempt))
            echo "rsync of \$file failed on attempt \$attempt; retrying in \${backoff}s..."
            sleep \$backoff
        done
        if [ \$success -ne 1 ]; then
            echo "ERROR: rsync of \$file failed after 5 attempts"
            exit 1
        fi
    done

    echo "Successfully copied results to: ${targetInfo.sshHost}:${targetDir}"
    """
}

process publishFusedChannelsToSource {
    tag "publish fused channels for ${base_name}"
    maxForks 1  // serialize haas<->cluster transfers to avoid bandwidth/disk contention

    input:
    tuple val(base_name), path(channel_files), val(output_path)

    script:
    def targetInfo = PathUtils.parseOutputPath(output_path)

    """
    # The destination (${targetInfo.sshHost}:${targetInfo.remotePath}) is a CIFS/SMB
    # share; transient I/O errors (rsync exit 11/23, often AFTER the bytes are across)
    # surface as task failures. Retry mkdir and each rsync with backoff so a single
    # blip doesn't abort the whole run. rsync --inplace makes retries resume cheaply.
    for f in ${channel_files}; do
        # Extract channel number from filename (e.g. _C0.tiff -> 0)
        ch_num=\$(echo "\$f" | grep -oP '_C\\K[0-9]+(?=\\.tiff)')
        if [ -z "\$ch_num" ]; then
            echo "WARNING: Could not extract channel number from \$f, skipping"
            continue
        fi

        target_dir="${targetInfo.remotePath}/ch\${ch_num}"
        echo "Publishing \$f to ${targetInfo.sshHost}:\${target_dir}/"

        for attempt in 1 2 3; do
            if ssh ${targetInfo.sshHost} "mkdir -p \${target_dir}"; then break; fi
            if [ \$attempt -eq 3 ]; then echo "ERROR: mkdir failed after 3 attempts"; exit 1; fi
            echo "mkdir attempt \$attempt failed; retrying in \$((attempt * 2))s..."
            sleep \$((attempt * 2))
        done

        success=0
        for attempt in 1 2 3 4 5; do
            if rsync -rltvL --progress --inplace --no-perms --no-owner --no-group --no-times --modify-window=1 \\
                "\$f" "${targetInfo.sshHost}:\${target_dir}/"; then
                success=1
                break
            fi
            backoff=\$((2 ** attempt))
            echo "rsync of \$f failed on attempt \$attempt; retrying in \${backoff}s..."
            sleep \$backoff
        done
        if [ \$success -ne 1 ]; then
            echo "ERROR: rsync of \$f failed after 5 attempts"
            exit 1
        fi
    done

    echo "Successfully published fused channels to ${targetInfo.sshHost}:${targetInfo.remotePath}/ch*/"
    """
}

process stageFilesRSyncSSH {
    tag "stageRSyncSSH_${ssh_path.split('/')[-1]}"
    maxForks 1  // serialize haas<->cluster transfers to avoid bandwidth/disk contention

    // Disable Nextflow's automatic staging
    stageInMode 'copy'
    
    input:
    val(ssh_path)
    
    output:
    path "${ssh_path.split('/')[-1]}", emit: staged_file
    
    script:
    def filename = ssh_path.split('/')[-1]
    """
    rsync -avz --progress "${ssh_path}" ./
    
    if [ ! -f "${filename}" ]; then
        echo "ERROR: File transfer failed"
        exit 1
    fi
    """
}