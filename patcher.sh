#!/bin/bash

# Step 1: Install dependencies
sudo apt-get update
sudo apt-get install -y git wget zip unzip xmlstarlet apksigner sdkmanager python3-pip
pip3 install ConfigObj

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

# Function to decompile and recompile JAR files
process_jar() {
    local jar_file="$1"

    # Unzip jar file
    echo "Decompiling $jar_file..."
    unzip -q "$jar_file" -d "${jar_file}.out"

    # Decompile each classes.dex file
    for dex_file in "${jar_file}.out/"*.dex; do
        java -jar bin/baksmali.jar d "$dex_file" -o "${dex_file}.out"
        rm "$dex_file"
    done

    # Locate and modify each target smali file
    local apk_signature_verifier=$(sudo find "${jar_file}.out" -name "ApkSignatureVerifier.smali")
    local package_manager_service=$(sudo find "${jar_file}.out" -name "PackageManagerService\$PackageManagerInternalImpl.smali")
    local package_impl=$(sudo find "${jar_file}.out" -name "PackageImpl.smali")

    # Run the Python script to patch the .smali files if they are found
    if [[ -n "$apk_signature_verifier" ]]; then
        python3 patch_smali.py "getMinimumSignatureSchemeVersionForTargetSdk" true "$apk_signature_verifier"
    fi

    if [[ -n "$package_manager_service" ]]; then
        python3 patch_smali.py "isPlatformSigned" true "$package_manager_service"
    fi

    if [[ -n "$package_impl" ]]; then
        python3 patch_smali.py "isSignedWithPlatformKey" true "$package_impl"
    fi

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

# Python script to patch smali files
cat << 'EOF' > patch_smali.py
import sys
from configobj import ConfigObj

def Linecounter(phrase, source, isText=0, startsAt=0):
    result = []
    if isText:
        if isText == 1 or isText == True:
            source = source.splitlines()
        for (i, line) in enumerate(source):
            if i >= startsAt: 
                if phrase in line :
                    result.append(i)
        return result
    else:
        with open(source, 'r') as f:
            return Linecounter(phrase, f, 2, startsAt)
    return False

def lineNumByPhrase(phrase, source, isText=0, startsAt=0):
    if isText:
        if isText == 1 or isText == True:
            source = source.splitlines()
        for (i, line) in enumerate(source):
            if i >= startsAt: 
                if phrase in line :
                    return i
    else:
        with open(source, 'r') as f:
            return lineNumByPhrase(phrase, f, 2, startsAt)
    return False

def fileReplaceRange(filename, startIndex, endIndex, content):
    if startIndex:
        lines = []
        with open(filename, 'r') as f:
            lines = f.readlines()

        with open(filename, 'w') as f:
            wrote = False
            for i, line in enumerate(lines):
                if i not in range(startIndex, endIndex + 1):
                    f.write(line)
                else:
                    if not wrote:
                        f.write(content + '\n')
                        wrote = True

true_content = """
    .locals 1

    const v0, 0x1

    return v0
"""

if sys.argv[2] == "true":
    replaceWith = true_content

replaceFile = sys.argv[3]
phraseStart = " " + str(sys.argv[1]) + "("
phraseEnd = '.end method'

if len(sys.argv) - 1 > 0:
    counter = Linecounter(phraseStart, replaceFile)
    temp=0
    for linez in counter:
        startIndex = lineNumByPhrase(phraseStart, replaceFile, 0, temp) + 1
        endIndex = lineNumByPhrase(phraseEnd, replaceFile, 0, (startIndex -1 )) -1
        fileReplaceRange(replaceFile, startIndex, endIndex, replaceWith)
        temp = startIndex
EOF

# Process framework.jar
echo "Starting patching of framework.jar..."
process_jar "framework.jar"

# Process services.jar
echo "Starting patching of services.jar..."
process_jar "services.jar"

# Move files to the module folder
mv framework.jar-mod module/system/framework/framework.jar
mv services.jar-mod module/system/framework/services.jar

# Package the module
7za a -tzip -mx=0 framework_patch_module.zip module/.
