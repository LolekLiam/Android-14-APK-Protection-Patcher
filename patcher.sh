#!/bin/bash

# Step 1: Install dependencies
sudo apt-get update
sudo apt-get install -y git wget zip unzip xmlstarlet apksigner sdkmanager

# Step 2: Set up Android SDK
wget https://googledownloads.cn/android/repository/commandlinetools-linux-11076708_latest.zip
mkdir -p ~/android_sdk/cmdline-tools/latest
unzip -q commandlinetools-linux-11076708_latest.zip -d ~/android_sdk/cmdline-tools/latest

# Define ANDROID_HOME and add it to PATH
export ANDROID_HOME=~/android_sdk
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"
sdkmanager --sdk_root=$ANDROID_HOME --install "platform-tools"
sdkmanager --sdk_root=$ANDROID_HOME --install "build-tools;34.0.0"
export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools/34.0.0"

# Wait for zipalign to be available in the correct directory
while [ ! -f "$ANDROID_HOME/build-tools/34.0.0/zipalign" ]; do
    echo "Waiting for zipalign to be available..."
    sleep 2
done

# Define fixed zipalign function as zipalign_f
zipalign_f() {
    "$ANDROID_HOME/build-tools/34.0.0/zipalign" "$@"
}

# Function to decompile, modify, and recompile .dex files
process_jar() {
    local jar_file="$1"
    local out_dir="$2"
    local smali_edit_func="$3"
    local smali_filenames=("${@:4}")

    # Unzip jar file
    unzip "$jar_file" -d "$out_dir" && cd "$out_dir" || exit 1

    # Decompile, modify, and recompile each classes.dex file
    for dex_file in classes*.dex; do
        java -jar ../bin/baksmali.jar d "$dex_file" -o "${dex_file}.out"
        
        # Find and modify each specified smali file
        for smali_file in "${smali_filenames[@]}"; do
            smali_path=$(find "${dex_file}.out" -type f -name "$smali_file")
            if [ -n "$smali_path" ]; then
                $smali_edit_func "$smali_path"
            fi
        done
        
        rm "$dex_file"
        java -jar ../bin/smali.jar a "${dex_file}.out" -o "$dex_file" --api 34
        rm -r "${dex_file}.out"
    done

    cd ..
}

# Step 3: Define smali edit functions
edit_framework_smali() {
    local smali_file="$1"
    sed -i 's/.line 640\n    const\/4 v0, 0x2\n\n    return v0/.locals 1\n\n    const v0, 0x1\n\n    return v0/' "$smali_file"
}

edit_services_smali() {
    local smali_file="$1"
    sed -i 's/.line 640\n    const\/4 v0, 0x2\n\n    return v0/.locals 1\n\n    const v0, 0x1\n\n    return v0/' "$smali_file"
}

# Process framework.jar
process_jar "framework.jar" "framework.jar.out" edit_framework_smali "ApkSignatureVerifier.smali"
7za a -tzip -mx=0 framework.jar_notal framework.jar.out/.
zipalign_f -p -v 4 framework.jar_notal framework-mod.jar

# Process services.jar
process_jar "services.jar" "services.jar.out" edit_services_smali "PackageManagerService\$PackageManagerInternalImpl.smali" "PackageImpl.smali"
7za a -tzip -mx=0 services.jar_notal services.jar.out/.
zipalign_f -p -v 4 services.jar_notal services-mod.jar

# Move files to the module folder
mv framework-mod.jar module/system/framework/framework.jar
mv services-mod.jar module/system/framework/services.jar

# Package the module
7za a -tzip -mx=0 framework_patch_module.zip module/.
