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

# Wait for zipalign to be available
while [ ! -f "$ANDROID_HOME/build-tools/34.0.0/zipalign" ]; do
    echo "Waiting for zipalign to be available..."
    sleep 2
done

# Define custom zipalign function as zipalign_f
zipalign_f() {
    "$ANDROID_HOME/build-tools/34.0.0/zipalign" "$@"
}

# Define the modified .smali method
return_true="
    .locals 1

    const v0, 0x1

    return v0
"

# Function to find and replace content in smali files
replace_method() {
    local smali_file="$1"
    local method_signature="$2"
    local replacement_content="$3"

    start_line=$(grep -n ".method" "$smali_file" | grep "$method_signature" | cut -d: -f1)
    end_line=$(grep -n ".end method" "$smali_file" | grep -A1 -m1 "^$start_line" | tail -n1 | cut -d: -f1)

    if [ -n "$start_line" ] && [ -n "$end_line" ]; then
        sed -i "$((start_line + 1)),$((end_line - 1))d" "$smali_file"
        sed -i "${start_line}a$replacement_content" "$smali_file"
    fi
}

# Jar utility to handle decompiling and reassembling dex files
jar_util() {
    local action="$1"
    local jar_name="$2"
    
    if [ "$action" == "d" ]; then
        echo "Decompiling $jar_name..."
        unzip -q "$jar_name" -d "${jar_name}.out"
        for dex_file in "${jar_name}.out/"*.dex; do
            java -jar ../bin/baksmali.jar d "$dex_file" -o "${dex_file}.out"
            rm "$dex_file"
        done
    elif [ "$action" == "a" ]; then
        echo "Reassembling $jar_name..."
        for dex_folder in "${jar_name}.out/"*.out; do
            java -jar ../bin/smali.jar a "$dex_folder" -o "${dex_folder%.out}" --api 34
            rm -r "$dex_folder"
        done
        7za a -tzip -mx=0 "${jar_name}_notal" "${jar_name}.out/."
        zipalign_f -p -v 4 "${jar_name}_notal" "$jar_name"
    fi
}

# Process framework.jar
echo "Starting patching of framework.jar..."
jar_util d "framework.jar"
replace_method "framework.jar.out/classes.dex.out/ApkSignatureVerifier.smali" "getMinimumSignatureSchemeVersionForTargetSdk" "$return_true"
jar_util a "framework.jar"

# Process services.jar
echo "Starting patching of services.jar..."
jar_util d "services.jar"
replace_method "services.jar.out/classes.dex.out/PackageManagerService\$PackageManagerInternalImpl.smali" "isPlatformSigned" "$return_true"
replace_method "services.jar.out/classes.dex.out/PackageImpl.smali" "isSignedWithPlatformKey" "$return_true"
jar_util a "services.jar"

# Move files to the module folder
mv framework.jar module/system/framework/framework.jar
mv services.jar module/system/framework/services.jar

# Package the module
7za a -tzip -mx=0 framework_patch_module.zip module/.
