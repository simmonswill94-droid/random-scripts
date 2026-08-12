/*
 * batch_merge_channels_single_folder
 * ------------------------------------
 * Merges single-channel TIFFs into multi-channel composite images.
 *
 * REQUIREMENTS:
 * - All channel images live in ONE folder (no need to pre-sort into
 *   per-channel folders).
 * - Filenames must end in "_C<n>.tif", where <n> is the channel index
 *   (e.g. "L4440__1_XY1763041170_Z00_T0_C0.tif", "..._C1.tif", etc.)
 *   Everything before "_C<n>.tif" is treated as the image's shared
 *   "base name" and is used to group its channels together.
 * - Spaces and special characters in filenames are fine — no
 *   renaming/normalization script needed beforehand.
 *
 * WHAT IT DOES:
 * 1. Asks how many channels to merge, and lets you assign a display
 *    color + min/max display range to each channel.
 * 2. Scans the input folder, groups files by base name, and matches
 *    up their channels.
 * 3. For each complete set, merges the channels into one composite
 *    TIFF and saves it to the output folder.
 * 4. Any image missing one or more channels is skipped (not merged)
 *    and noted in a log file rather than crashing the batch.
 * 5. Writes merge_log.txt to the output folder summarizing what was
 *    merged vs. skipped, for later review.
 *
 * NOTE: This macro does not use try/catch — some ImageJ/Fiji builds
 * don't support it. If a truly unexpected error occurs mid-run
 * (e.g. a corrupt file), the macro will stop with Fiji's standard
 * error dialog rather than skipping gracefully.
 *
 * FIX (2026-08-11): "Merge Channels..." always assembles its output
 * stack in fixed slot order (c1=Red, c2=Green, c3=Blue, c4=Gray,
 * c5=Cyan, c6=Magenta, c7=Yellow) — NOT in the order channels were
 * passed into the command. Previously, the per-channel min/max
 * display values were applied using the original input channel order
 * (C0, C1, C2, ...), which is only correct if colors happen to be
 * assigned in that same slot order. If e.g. C0 was set to Gray (c4)
 * and C1 was set to Green (c2), the merged stack put Green first, but
 * C0's min/max got applied to stack position 1 (i.e. onto Green
 * instead of Gray). This version computes the actual output channel
 * order (sorted by slot number) and applies each channel's min/max
 * to its real position in the merged stack.
 */

macro "batch_merge_channels_single_folder" {
    setBatchMode(true); // suppresses image windows from popping up during the run — much faster

    // ---- Ask how many channels this dataset has (2, 3, 4, etc.) ----
    Dialog.create("Batch Merge Setup");
    Dialog.addNumber("Number of channels:", 4);
    Dialog.show();
    nChannels = Dialog.getNumber();

    // ---- Fiji's built-in merge-channel color slots ----
    // These correspond to ImageJ's "Merge Channels..." command options:
    // c1=Red, c2=Green, c3=Blue, c4=Gray, c5=Cyan, c6=Magenta, c7=Yellow
    // IMPORTANT: Merge Channels always assembles the OUTPUT stack in this
    // slot order (c1, c2, c3, ...), regardless of the order the c*=...
    // arguments are listed in the command string. Any code that maps
    // per-channel settings onto the merged stack must account for this.
    colorNames = newArray("Red","Green","Blue","Gray","Cyan","Magenta","Yellow");
    colorSlots = newArray("c1","c2","c3","c4","c5","c6","c7");

    // Per-channel settings, filled in via dialogs below
    slotAssignment = newArray(nChannels); // which color slot (c1-c7) each channel maps to
    minVals = newArray(nChannels);        // display min for each channel
    maxVals = newArray(nChannels);        // display max for each channel

    // ---- Ask for color + display range for each channel ----
    // Channel numbering here matches the "_C<n>" suffix in filenames
    // (C0 = first dialog, C1 = second dialog, etc.)
    for (c=0; c<nChannels; c++) {
        Dialog.create("Channel C" + c + " settings");
        Dialog.addChoice("Display color:", colorNames, colorNames[c % colorNames.length]);
        Dialog.addNumber("Min display value:", 0);
        Dialog.addNumber("Max display value:", 4095);
        Dialog.show();
        chosenColor = Dialog.getChoice();
        minVals[c] = Dialog.getNumber();
        maxVals[c] = Dialog.getNumber();

        // Convert the chosen color name (e.g. "Green") into its
        // merge-command slot (e.g. "c2") for later use
        for (k=0; k<colorNames.length; k++) {
            if (colorNames[k]==chosenColor) slotAssignment[c] = colorSlots[k];
        }
    }

    // ---- Pick input/output folders ----
    inDir = getDirectory("Choose folder containing all channel images");
    outDir = getDirectory("Choose output folder");
    allFiles = getFileList(inDir);

    // ---- Set up the log file (tracks what was merged/skipped) ----
    logPath = outDir + "merge_log.txt";
    File.saveString("Batch merge log — " + getTime() + "\n", logPath);

    // ---- Build a list of unique "base names" ----
    // Strips the trailing "_C<n>" so that, e.g., both
    // "sample1_C0.tif" and "sample1_C1.tif" collapse to "sample1"
    // — one entry per acquisition, regardless of channel count.
    bases = newArray(0);
    for (i=0; i<allFiles.length; i++) {
        f = allFiles[i];
        if (!endsWith(toLowerCase(f), ".tif")) continue; // skip non-TIFF files (e.g. .DS_Store)
        b = getBaseName(f);
        if (indexOfArray(bases, b) == -1) {
            bases = Array.concat(bases, b);
        }
    }

    processed = 0; // count of successfully merged images
    skipped = 0;   // count of images skipped due to missing channel(s)

    // ---- Main loop: one iteration per unique image (base name) ----
    for (bi=0; bi<bases.length; bi++) {
        base = bases[bi];
        chanFiles = newArray(nChannels); // filenames for this image's channels
        allFound = true;

        // For each expected channel, look for "<base>_C<c>.tif" in the folder
        for (c=0; c<nChannels; c++) {
            target = base + "_C" + c + ".tif";
            found = "";
            for (i=0; i<allFiles.length; i++) {
                if (toLowerCase(allFiles[i]) == toLowerCase(target)) {
                    found = allFiles[i];
                }
            }
            chanFiles[c] = found;
            if (found=="") allFound = false;
        }

        // If any channel is missing, skip this image and log why —
        // rather than crashing or merging an incomplete/misaligned set
        if (!allFound) {
            missing = "";
            for (c=0; c<nChannels; c++) if (chanFiles[c]=="") missing += "C"+c+" ";
            msg = "SKIPPED " + base + " — missing: " + missing;
            print(msg);
            File.append(msg, logPath);
            skipped++;
            continue;
        }

        // ---- Show progress in the status bar / progress bar ----
        showStatus("Merging " + (bi+1) + "/" + bases.length + ": " + base);
        showProgress(bi, bases.length);

        // ---- Open each channel image and rename its window ----
        // Renaming to "ch_0", "ch_1", etc. avoids problems with
        // spaces/special characters in the original filenames when
        // building the Merge Channels command below.
        mergeArgs = "";
        for (c=0; c<nChannels; c++) {
            open(inDir + chanFiles[c]);
            rename("ch_" + c);
            mergeArgs += slotAssignment[c] + "=ch_" + c + " ";
        }
        mergeArgs += "create"; // "create" tells Merge Channels to build a composite hyperstack

        run("Merge Channels...", mergeArgs);

        // ---- Figure out the ACTUAL channel order in the merged stack ----
        // Merge Channels always orders its output by slot number
        // (c1, c2, c3, ...), not by the order channels were listed in
        // mergeArgs. outputOrder[pos] = original input channel index
        // (c, matching "_C<c>.tif") that ends up at stack position "pos".
        slotNums = newArray(nChannels);
        outputOrder = newArray(nChannels);
        for (c=0; c<nChannels; c++) {
            slotNums[c] = parseInt(substring(slotAssignment[c], 1, lengthOf(slotAssignment[c]))); // "c4" -> 4
            outputOrder[c] = c;
        }
        // simple ascending sort of outputOrder by slotNums
        for (i=0; i<nChannels; i++) {
            for (j=i+1; j<nChannels; j++) {
                if (slotNums[outputOrder[j]] < slotNums[outputOrder[i]]) {
                    tmp = outputOrder[i];
                    outputOrder[i] = outputOrder[j];
                    outputOrder[j] = tmp;
                }
            }
        }

        // ---- Apply per-channel display (brightness/contrast) settings ----
        // using the REAL stack position for each original channel, not
        // the input order.
        for (pos=0; pos<nChannels; pos++) {
            origC = outputOrder[pos];
            Stack.setChannel(pos+1); // Stack.setChannel is 1-indexed
            setMinAndMax(minVals[origC], maxVals[origC]);
        }
        Stack.setDisplayMode("composite");

        // ---- Save merged image and clean up before the next iteration ----
        saveAs("Tiff", outDir + base + "_merged.tif");
        close("*"); // close all open images so memory doesn't build up over a long batch
        processed++;
    }

    // ---- Final summary, printed and logged ----
    summary = "Done. Merged: " + processed + " | Skipped/errored: " + skipped;
    print(summary);
    File.append(summary, logPath);
    setBatchMode(false);
}

// ---- Helper: strips a trailing "_C<number>" from a filename ----
// e.g. "sample1_C0.tif" -> "sample1"
function getBaseName(filename) {
    name = File.getNameWithoutExtension(filename);
    name = replace(name, "_C[0-9]+$", "");
    return name;
}

// ---- Helper: returns the index of val in arr, or -1 if not found ----
// (ImageJ macro language has no built-in array search)
function indexOfArray(arr, val) {
    for (k=0; k<arr.length; k++) {
        if (arr[k]==val) return k;
    }
    return -1;
}
