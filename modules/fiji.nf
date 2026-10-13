process setupFiji {
    tag 'fiji-setup'
    
    // This tells Nextflow to store results in the specified directory
    storeDir params.fiji_cache_dir
    
    output:
    path "fiji_installation", emit: fiji_ready
    
    when:
    !file("${params.fiji_cache_dir}/fiji_installation").exists()
    
    script:
    """
    # Check and install dependencies if needed
    if ! command -v unzip &> /dev/null; then
        echo "Installing unzip..."
        sudo apt update && sudo apt install -y unzip
    fi

    # Download and setup Fiji (work in current directory)
    wget https://downloads.imagej.net/fiji/stable/fiji-stable-linux64-jdk.zip
    unzip fiji-stable-linux64-jdk.zip
    rm fiji-stable-linux64-jdk.zip

    # Change to Fiji.app directory before running commands
    cd Fiji.app
    
    # Update Fiji twice
    ./ImageJ-linux64 --ij2 --headless --update update
    ./ImageJ-linux64 --ij2 --headless --update update
    
    # Activate update sites
    ./ImageJ-linux64 --update add-update-sites "PTBIOP" "https://biop.epfl.ch/Fiji-Update/" "Zeiss Quick Start Reader" "https://biop.epfl.ch/Fiji-CZI/" "BigStitcher" "https://sites.imagej.net/BigStitcher/"
    
    # Update with new sites
    ./ImageJ-linux64 --ij2 --headless --update update
    
    # Create a marker directory
    cd ..
    mkdir fiji_installation
    mv Fiji.app fiji_installation/
    touch fiji_installation/setup_complete
    """
}

