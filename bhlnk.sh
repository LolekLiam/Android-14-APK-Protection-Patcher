#!/bin/bash
dir=$(pwd)
repM="python3 $dir/bin/strRep.py"

# Function to get file directory
get_file_dir() {
    if [[ $1 ]]; then
        test=$(sudo find "$dir/img_temp/" -type f -name "$1")
        for i in $test; do
            echo $i
        done
    else 
        return 0
    fi
}

# Function to move files to specified folders
mvst() {
    scr_folder=$(dirname $(sudo find -name $1 | sed -e 's,^\./,,' ))
    if [[ $3 ]]; then
        scr_folder=$(echo $scr_folder | cut -d'/' -f2-)
    fi
    des_folder=$(sudo find -name $2 | sed -e 's,^\./,,' )
    mkdir -p $des_folder/$scr_folder
    mv $(sudo find -type f -name $1 | sed -e 's,^\./,,' ) $des_folder/$scr_folder
}

# Function to decompile and recompile .dex files with debug output
jar_util() {
    cd $dir

    if [[ ! -d $dir/jar_temp ]]; then
        mkdir $dir/jar_temp
    fi

    bak="java -jar $dir/bin/baksmali.jar d"
    sma="java -jar $dir/bin/smali-2.5.2.jar a"

    if [[ $1 == "d" ]]; then
        echo -ne "====> Patching $2 : "
        
        # Checking if the file exists
        if [[ $(get_file_dir $2 ) ]]; then
            sudo cp $(get_file_dir $2 ) $dir/jar_temp
            sudo chown $(whoami) $dir/jar_temp/$2
            unzip $dir/jar_temp/$2 -d $dir/jar_temp/$2.out >/dev/null 2>&1
            
            # Confirm directory creation
            if [[ -d $dir/jar_temp/"$2.out" ]]; then
                rm -rf $dir/jar_temp/$2
                for dex in $(sudo find $dir/jar_temp/"$2.out" -maxdepth 1 -name "*dex"); do
                    echo "====> Decompiling $dex with baksmali"
                    $bak $dex -o "$dex.out"
                    
                    # Check if decompilation was successful
                    if [[ -d "$dex.out" ]]; then
                        echo "Decompilation successful: $dex.out created"
                        rm -rf $dex
                    else
                        echo "Error: Failed to create $dex.out"
                    fi
                done
            else
                echo "Error: Failed to create jar_temp/$2.out directory"
            fi
        else
            echo "Error: $2 not found for patching"
        fi
    elif [[ $1 == "a" ]]; then
        if [[ -d $dir/jar_temp/$2.out ]]; then
            cd $dir/jar_temp/$2.out
            for fld in $(sudo find -maxdepth 1 -name "*.out"); do
                echo "====> Recompiling $fld with smali"
                $sma $fld -o $(echo ${fld//.out}) --api 34
                
                # Check if recompilation was successful
                if [[ -f $(echo ${fld//.out}) ]]; then
                    echo "Recompilation successful: $(echo ${fld//.out}) created"
                    rm -rf $fld
                else
                    echo "Error: Failed to create $(echo ${fld//.out})"
                fi
            done
            7za a -tzip -mx=0 $dir/jar_temp/$2_notal $dir/jar_temp/$2.out/. >/dev/null 2>&1
        else
            echo "Error: $2.out directory not found for recompilation"
        fi
    fi
}

# Main processing block
echo "Starting processing..."
count=$(ls -dq classes* | wc -l)
mkdir "classes$count.dex.out"

# Verify directory creation for debugging
if [[ -d "classes$count.dex.out" ]]; then
    echo "Directory created successfully: classes$count.dex.out"
else
    echo "Error: Failed to create classes$count.dex.out"
fi

repM () {
	if [[ $4 == "r" ]]; then
		if [[ -f $3 ]]; then
			$repM $1 $2 $3
		fi
	elif [[ $4 == "f" ]]; then
		for i in $3; do
			$repM $1 $2 $i
		done
	else
		file=$(sudo find -name $3)
		if [[ $file ]]; then
			$repM $1 $2 $file
		fi
	fi
}

framework() {

	jar_util d 'framework.jar' fw 5 5

	count=$(ls -dq classes* | wc -l)
	mkdir "classes$count.dex.out"

	repM 'getMinimumSignatureSchemeVersionForTargetSdk' true ApkSignatureVerifier.smali
 
	mvst 'ApkSignatureVerifier.smali' "classes$count.dex.out" 
	
	jar_util a 'framework.jar' fw 5 5
}

services() {
	
	jar_util d "services.jar" fw

	count=$(ls -dq classes* | wc -l)
	mkdir "classes$count.dex.out" 

	repM 'isPlatformSigned' true 'PackageManagerService$PackageManagerInternalImpl.smali'
	repM 'isSignedWithPlatformKey' true 'PackageImpl.smali'

	mvst 'PackageManagerService$PackageManagerInternalImpl.smali' "classes$count.dex.out" 
	mvst 'PackageImpl.smali' "classes$count.dex.out" 
		
	jar_util a "services.jar" fw
}


if [[ ! -d $dir/jar_temp ]]; then

	mkdir $dir/jar_temp
	
fi

framework
services

if  [ -f $dir/jar_temp/framework.jar ]; then
		sudo cp -rf $dir/jar_temp/*.jar $dir/module/system/framework
	else
		echo "Fail to copy framework"
fi
