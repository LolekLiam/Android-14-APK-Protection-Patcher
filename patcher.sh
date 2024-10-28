#!/bin/bash

# Step 1: Install dependencies
sudo apt-get update
sudo apt-get install -y git wget zip unzip xmlstarlet apksigner sdkmanager

# Step 2: Set up Android SDK in the correct directory
wget https://googledownloads.cn/android/repository/commandlinetools-linux-11076708_latest.zip
mkdir -p ~/android_sdk/cmdline-tools/latest
unzip -q commandlinetools-linux-11076708_latest.zip -d ~/android_sdk/cmdline-tools/latest

# Define ANDROID_HOME and ANDROID_SDK_ROOT, and add to PATH
export ANDROID_HOME=~/android_sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"

# Install necessary build tools
sdkmanager --sdk_root=$ANDROID_SDK_ROOT --install "platform-tools" "build-tools;34.0.0"
export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools/34.0.0"

# Wait for zipalign to be available in the correct directory
while [ ! -f "$ANDROID_HOME/build-tools/34.0.0/zipalign" ]; do
    echo "Waiting for zipalign to be available..."
    sleep 2
done

# Define custom zipalign function as zipalign_f
zipalign_f() {
    "$ANDROID_HOME/build-tools/34.0.0/zipalign" "$@"
}

# Define the replacement content for the smali method to always return true
return_true="
    .locals 1

    const v0, 0x1

    return v0
"

# Function to handle replacements in .smali files
repM() {
    local phrase="$1"
    local content="$2"
    local smali_file="$3"

    if [[ -f "$smali_file" ]]; then
        start_line=$(grep -n ".method" "$smali_file" | grep "$phrase" | cut -d: -f1)
        end_line=$(grep -n ".end method" "$smali_file" | grep -A1 -m1 "^$start_line" | tail -n1 | cut -d: -f1)

        if [ -n "$start_line" ] && [ -n "$end_line" ]; then
            sed -i "$((start_line + 1)),$((end_line - 1))d" "$smali_file"
            sed -i "${start_line}a$content" "$smali_file"
        fi
    fi
}

# Function to decompile, modify, and recompile .dex files
process_jar() {
    local jar_file="$1"
    shift
    local smali_targets=("$@")

    # Unzip jar file
    echo "Decompiling $jar_file..."
    unzip -q "$jar_file" -d "${jar_file}.out"

    # Decompile each classes.dex file
    for dex_file in "${jar_file}.out/"*.dex; do
        java -jar bin/baksmali.jar d "$dex_file" -o "${dex_file}.out"
        rm "$dex_file"
    done

    # Locate and modify each target smali file
    for smali_file in "${smali_targets[@]}"; do
        smali_path=$(find "${jar_file}.out" -type f -name "$smali_file")
        if [ -n "$smali_path" ]; then
            if [[ "$smali_file" == "ApkSignatureVerifier.smali" ]]; then
                repM "getMinimumSignatureSchemeVersionForTargetSdk" "$return_true" "$smali_path"
            elif [[ "$smali_file" == "PackageManagerService\$PackageManagerInternalImpl.smali" ]]; then
                repM "isPlatformSigned" "$return_true" "$smali_path"
            elif [[ "$smali_file" == "PackageImpl.smali" ]]; then
                repM "isSignedWithPlatformKey" "$return_true" "$smali_path"
            fi
        fi
    done

    # Reassemble each dex file
    echo "Reassembling $jar_file..."
    for dex_folder in "${jar_file}.out/"*.out; do
        java -jar bin/smali.jar a "$dex_folder" -o "${dex_folder%.out}" --api 34
        rm -r "$dex_folder"
    done

    # Repack the JAR file
    7za a -tzip -mx=0 "${jar_file}_notal" "${jar_file}.out/."
    zipalign_f -p -v 4 "${jar_file}_notal" "$jar_file-mod"
}

# Process framework.jar
echo "Starting patching of framework.jar..."
process_jar "framework.jar" "ApkSignatureVerifier.smali"

# Process services.jar
echo "Starting patching of services.jar..."
process_jar "services.jar" "PackageManagerService\$PackageManagerInternalImpl.smali" "PackageImpl.smali"

# Move files to the module folder
mv framework.jar-mod module/system/framework/framework.jar
mv services.jar-mod module/system/framework/services.jar

# Package the module
7za a -tzip -mx=0 framework_patch_module.zip module/.
