#!/bin/bash

# Step 1: Install dependencies
sudo apt-get update
sudo apt-get install -y git wget zip unzip xmlstarlet zipalign apksigner sdkmanager

# Step 2: Set up Android SDK
wget https://googledownloads.cn/android/repository/commandlinetools-linux-11076708_latest.zip
mkdir -p ~/android_sdk
unzip commandlinetools-linux-11076708_latest.zip -d ~/android_sdk

export ANDROID_HOME="~/android_sdk"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"
sdkmanager --install "platform-tools"
sdkmanager "build-tools;34.0.0"
export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools/34.0.0"

# Fix for zipalign compatibility
sudo rm -f /usr/bin/zipalign
sudo ln -s ~/android_sdk/build-tools/34.0.0/zipalign /usr/bin/zipalign

# Function to decompile, modify, and recompile .dex files
process_jar() {
    local jar_file="$1"
    local out_dir="$2"
    local smali_edit_func="$3"
    local smali_paths=("${@:4}")

    # Unzip jar file
    unzip "$jar_file" -d "$out_dir" && cd "$out_dir" || exit 1

    # Decompile, modify, and recompile each classes.dex file
    for dex_file in classes*.dex; do
        java -jar ../bin/baksmali.jar d "$dex_file" -o "${dex_file}.out"
        $smali_edit_func "${dex_file}.out" "${smali_paths[@]}"
        rm "$dex_file"
        java -jar ../bin/smali-2.5.2.jar a "${dex_file}.out" -o "$dex_file" --api 34
        rm -r "${dex_file}.out"
    done

    # Go back to the parent directory
    cd ..
}

# Step 3: Define smali edit functions
edit_framework_smali() {
    local smali_dir="$1"
    sed -i 's/.line 640\n    const\/4 v0, 0x2\n\n    return v0/.locals 1\n\n    const v0, 0x1\n\n    return v0/' "$smali_dir/ApkSignatureVerifier.smali"
}

edit_services_smali() {
    local smali_dir="$1"
    sed -i 's/.line 640\n    const\/4 v0, 0x2\n\n    return v0/.locals 1\n\n    const v0, 0x1\n\n    return v0/' "$smali_dir/PackageManagerService\$PackageManagerInternalImpl.smali"
    sed -i 's/.line 640\n    const\/4 v0, 0x2\n\n    return v0/.locals 1\n\n    const v0, 0x1\n\n    return v0/' "$smali_dir/PackageImpl.smali"
}

# Process framework.jar
process_jar "framework.jar" "framework.jar.out" edit_framework_smali "ApkSignatureVerifier.smali"
7za a -tzip -mx=0 framework.jar_notal framework.jar.out/.
zipalign -p -v 4 framework.jar_notal framework-mod.jar

# Process services.jar
process_jar "services.jar" "services.jar.out" edit_services_smali "PackageManagerService\$PackageManagerInternalImpl.smali" "PackageImpl.smali"
7za a -tzip -mx=0 services.jar_notal services.jar.out/.
zipalign -p -v 4 services.jar_notal services-mod.jar

# Move files to the module folder
mv framework-mod.jar module/system/framework/framework.jar
mv services-mod.jar module/system/framework/services.jar

# Package the module
7za a -tzip -mx=0 framework_patch_module.zip module/.
