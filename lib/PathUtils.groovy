class PathUtils {
    /**
     * Extracts filename from path (local or SSH) and removes extension
     * Examples:
     *   "/path/to/file.czi" -> "file"
     *   "user@host:/path/to/file.czi" -> "file"
     */
    static String extractBasename(String pathStr) {
        def filename = pathStr.split('/')[-1]
        return filename.replaceAll(/\.[^.]+$/, '')
    }

    /**
     * Extracts canonical key for matching across processing stages
     * Removes extension AND all processing suffixes (including channel suffixes)
     * Examples:
     *   "file_bigstitcher_aligned_tile.xml" -> "file"
     *   "/path/to/file_icp_refined_asr_C0.tiff" -> "file"
     *   "/path/to/file_C1.tiff" -> "file"
     */
    static String getBaseKey(String pathStr) {
        def basename = extractBasename(pathStr)
        // Only strip suffixes at the END of the name, so a brain ID that happens
        // to contain e.g. "_tile" or "_C2" isn't mangled into another brain's key
        return basename.replaceAll(/(?:_(?:bigstitcher|aligned|tile|icp_refined|asr|C\d+))+$/, '')
    }

    /**
     * True for remote "user@host:/path" inputs, false for local paths
     */
    static boolean isSshPath(String pathStr) {
        return pathStr.contains('@') && pathStr.contains(':')
    }

    /**
     * Parses SSH path into components
     * Input: "user@host:/remote/path/to/file.czi"
     * Returns: [sshHost: "user@host", remotePath: "/remote/path/to/file.czi",
     *           remoteDir: "/remote/path/to", basename: "file"]
     */
    static Map parseSshPath(String sshPath) {
        def parts = sshPath.split(':')
        def sshHost = parts[0]  // user@host
        def remotePath = parts[1]  // /remote/path/to/file.czi
        def remoteDir = remotePath.substring(0, remotePath.lastIndexOf('/'))
        def basename = remotePath.split('/')[-1].replaceAll(/\.[^.]+$/, '')

        return [
            sshHost: sshHost,
            remotePath: remotePath,
            remoteDir: remoteDir,
            basename: basename
        ]
    }

    /**
     * Parses an output SSH path (directory, no file extension)
     * Input: "user@host:/mnt/lsens-analysis/Lana_Smith/MS181"
     * Returns: [sshHost: "user@host", remotePath: "/mnt/lsens-analysis/Lana_Smith/MS181"]
     */
    static Map parseOutputPath(String outputPath) {
        def parts = outputPath.split(':')
        return [
            sshHost: parts[0],
            remotePath: parts[1]
        ]
    }
}
