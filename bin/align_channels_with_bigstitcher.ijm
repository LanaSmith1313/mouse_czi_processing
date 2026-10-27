#@String xml_file
#@int pairwise_shifts_downsamples_x
#@int pairwise_shifts_downsamples_y
#@int pairwise_shifts_downsamples_z
#@double filter_min_r
#@double filter_max_shift

print("Channel Alignment Parameters:");
print("XML file: " + xml_file);
print("Pairwise shifts downsamples - x: " + pairwise_shifts_downsamples_x + ", y: " + pairwise_shifts_downsamples_y + ", z: " + pairwise_shifts_downsamples_z);
print("Filter min r: " + filter_min_r);
print("Filter max shift (px): " + filter_max_shift);

// Step 1: Calculate pairwise shifts
print("Step 1: Calculating pairwise shifts...");
run("Calculate pairwise shifts ...",
		"select=[" + xml_file + "] " +
				"process_angle=[All angles] " +
				"process_channel=[All channels] " +
				"process_illumination=[All illuminations] " +
				"process_tile=[All tiles] " +
				"process_timepoint=[All Timepoints] " +
				"method=[Phase Correlation] " +
				"show_expert_grouping_options " +
				"how_to_treat_timepoints=[treat individually] " +
				"how_to_treat_channels=compare " +
				"how_to_treat_illuminations=group " +
				"how_to_treat_angles=[treat individually] " +
				"how_to_treat_tiles=[treat individually] " +
				"downsample_in_x=" + pairwise_shifts_downsamples_x + " " +
				"downsample_in_y=" + pairwise_shifts_downsamples_y + " " +
				"downsample_in_z=" + pairwise_shifts_downsamples_z + " " +
				"channels=[use Channel 0] "
);
//I ommitted this option as it was giving me errors -> "channels=[use Channel Cam1] " --> This was fixed by Oli

// Step 2: Filter pairwise shifts
print("Step 2: Filtering pairwise shifts...");
run("Filter pairwise shifts ...", "select=[" + xml_file + "] " +
		"filter_by_link_quality " +
		"min_r=" + filter_min_r + " " +
		"max_r=1 " +
		"filter_by_total_shift_magnitude " +
		"max_displacement=" + filter_max_shift);

print("Step 3: Optimizing globally and applying shifts...");
run("Optimize globally and apply shifts ...",
		"select=[" + xml_file + "] " +
				"process_angle=[All angles] " +
				"process_channel=[All channels] " +
				"process_illumination=[All illuminations] " +
				"process_tile=[All tiles] " +
				"process_timepoint=[All Timepoints] " +
				"relative=2.500 " +
				"absolute=3.500 " +
				"global_optimization_strategy=[Two-Round using metadata to align unconnected Tiles] " +
				"show_expert_grouping_options " +
				"how_to_treat_timepoints=[treat individually] " +
				"how_to_treat_channels=compare " +
				"how_to_treat_illuminations=group " +
				"how_to_treat_angles=[treat individually] " +
				"how_to_treat_tiles=[treat individually]"); 

print("Channel alignment completed successfully!");
print("Processed XML file: " + xml_file);

eval("script", "System.exit(0);"); // BigStitcher bug -> force quit