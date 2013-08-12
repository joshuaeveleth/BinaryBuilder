#!/bin/bash

# Launch and test all builds on all machines. Then notify the user of
# the status. In case of success, copy the resulting builds to byss.
# We assume all machines we need (byss, zula, amos, pfe25,
# centos-64-5, centos-32-5) are set up properly for login without
# password and their details are in .ssh/config.

# To do: When ISIS gets updated, need to update the base_system
# on each machine presumambly as that one is used in regressions.
# To do: Enable updating BinaryBuilder from git.
# To do: Think more about copying .sh files
# To do: See the .py to do list.
# To do: test rename_build.sh with 32 bit.
# To do: How to ensure that the stereo from right dir is executed
# To do: Create recipe for how to install sparse_disp and put that on amos and zula
# To do: Deal with the issues on the mac
# To do: test on zula runs at the same time!
# To do: Move build stuff to its own auto_build dir

version="2.2.2_post" # Must change the version in the future
byss="byss"
byssPath="/byss/docroot/stereopipeline/daily_build"
link="http://byss.arc.nasa.gov/stereopipeline/daily_build/index.html"
mailto="oleg.alexandrov@nasa.gov oleg.alexandrov@gmail.com"
sleepTime=30
buildDir=projects/BinaryBuilder     # must be relative to home dir
testDir=projects/StereoPipelineTest # must be relative to home dir
timestamp=$(date +%Y-%m-%d)
user=$(whoami)
#launchMachines="pfe25 amos zula" # temporary!!
#launchMachines="pfe25 zula amos" # temporary!!
launchMachines="pfe25" # pfe25 zula" # temporary!!
#launchMachines="amos" # temporary!!!
#launchMachines="zula amos" # temporary!!!
#zulaSlaves="zula" # temporary!!!
zulaSlaves="zula centos-64-5" # centos-32-5"

cd $HOME
if [ ! -d "$buildDir" ]; then echo "Error: Directory: $buildDir does not exist"; exit 1; fi;
if [ ! -d "$testDir" ];  then echo "Error: Directory: $testDir does not exist"; exit 1; fi;
cd $buildDir

for launchMachine in $launchMachines; do

    if [ "$launchMachine" = "zula" ]; then
        buildMachines=$zulaSlaves
    else
        buildMachines=$launchMachine
    fi

    for buildMachine in $buildMachines; do
        statusFile="status_"$buildMachine".txt"
        # Make sure all scripts are up-to-date on the target machine
        rsync -avz patches *py *sh $user@$launchMachine:$buildDir >/dev/null 2>&1

        # temporary!!!
        # Set the status to now building
        ssh $user@$launchMachine "echo NoTarballYet now_building > $buildDir/$statusFile 2>/dev/null" 2>/dev/null
        sleep 5; # Give the filesystem enough time to react
        ssh $user@$launchMachine "nohup nice -19 $buildDir/launch_slave.sh $buildMachine $buildDir $statusFile > $buildDir/output_$statusFile 2>&1&" 2>/dev/null
    done
done

# Wait until the builds are done and run the regressions.
# Note that on some machines more than one build happens,
# then do one regression run at a time.
while [ 1 ]; do
    allDone=1
    for launchMachine in $launchMachines; do

        if [ "$launchMachine" = "zula" ]; then
            buildMachines=$zulaSlaves
        else
            buildMachines=$launchMachine
        fi

        # See how many regressions are now running on the launch
        # machine and whether not all are done
        numRunning=0
        for buildMachine in $buildMachines; do
            statusFile="status_"$buildMachine".txt"
            statusLine=$(ssh $user@$launchMachine \
                "cat $buildDir/$statusFile 2>/dev/null" 2>/dev/null)
            tarBall=$( echo $statusLine | awk '{print $1}' )
            state=$( echo $statusLine | awk '{print $2}' )
            status=$( echo $statusLine | awk '{print $3}' )
            echo $(date) Status for $buildMachine is $tarBall $state $status
            if [ "$state" != "test_done" ]; then
                allDone=0
            fi
            if [ "$state" = "now_testing" ]; then
                ((numRunning++));
            fi
        done
        if [ "$numRunning" -ne 0 ]; then continue; fi

        # No regressions are running, see if to start one
        for buildMachine in $buildMachines; do
            statusFile="status_"$buildMachine".txt"
            statusLine=$(ssh $user@$launchMachine \
                "cat $buildDir/$statusFile 2>/dev/null" 2>/dev/null)
            tarBall=$( echo $statusLine | awk '{print $1}' )
            state=$( echo $statusLine | awk '{print $2}' )

            if [ "$state" = "build_done" ]; then
                # To do: Similar code exiss in run_tests.sh!
                # Build is done, no other builds are being tested,
                # so test the current build
                echo Will launch tests for $buildMachine
                ssh $user@$launchMachine "echo $tarBall now_testing > $buildDir/$statusFile 2>/dev/null" 2>/dev/null
                sleep 5; # Give the filesystem enough time to react
                ssh $user@$launchMachine "nohup nice -19 $buildDir/run_tests.sh $buildMachine $tarBall $testDir $buildDir $statusFile >> $buildDir/output_$statusFile 2>&1&" 2>/dev/null
                break # launch just one testing session at a time
            fi
        done

    done

    if [ $allDone -eq 1 ]; then
        break;
    fi
    echo Will sleep for $sleepTime seconds
    sleep $sleepTime
    echo " "

done

# Copy back the documentation processed on zula which has LaTeX.
# This must happen after all builds finished, as otherwise git
# will fetch an outdated version during build.
overallStatus="Success"
for launchMachine in $launchMachines; do
    if [ "$launchMachine" = "zula" ]; then
        rm -fv dist-add/asp_book.pdf
        echo Copying the documentation from $user@$launchMachine
        rsync -avz $user@$launchMachine:$buildDir/dist-add/asp_book.pdf \
            dist-add
        if [ ! -f "dist-add/asp_book.pdf" ]; then
            echo "Error: Missing dist-add/asp_book.pdf"
            overallStatus="Fail"
        fi
    fi
done

# Once the regressions are finished, copy the builds to the master
# machine, rename them for release, and record whether the regressions
# passed.
statusMasterFile="status_master.txt"
rm -f $statusMasterFile
echo "Machine and status" >> $statusMasterFile
count=0
for launchMachine in $launchMachines; do

    if [ "$launchMachine" = "zula" ]; then
        buildMachines=$zulaSlaves
    else
        buildMachines=$launchMachine
    fi

    numRunning=0
    for buildMachine in $buildMachines; do
        statusFile="status_"$buildMachine".txt"
        statusLine=$(ssh $user@$launchMachine \
            "cat $buildDir/$statusFile 2>/dev/null" 2>/dev/null)
        tarBall=$( echo $statusLine | awk '{print $1}' )
        state=$( echo $statusLine | awk '{print $2}' )
        status=$( echo $statusLine | awk '{print $3}' )
        echo $(date) Status for $buildMachine is $tarBall $state $status
        if [ "$status" != "Success" ]; then status="Fail"; fi
        if [ "$state" != "test_done" ]; then
            echo "Error: Expecting the state to be: test_done"
            status="Fail"
        fi

        mkdir -p asp_tarballs
        echo Copying $user@$launchMachine:$buildDir/$tarBall to asp_tarballs
        rsync -avz $user@$launchMachine:$buildDir/$tarBall asp_tarballs 2>/dev/null
        if [ ! -f "$HOME/$buildDir/$tarBall" ]; then
            echo "Error: Could not copy $HOME/$buildDir/$tarBall"
            status="Fail"
        fi
        if [ "$status" != "Success" ]; then overallStatus="Fail"; fi
        echo "Renaming build $tarBall"
        tarBall=$(./rename_build.sh $tarBall $version $timestamp)
        if [ ! -f "$tarBall" ]; then echo Missing $tarBall; status="Fail"; fi
        echo $buildMachine $status >> $statusMasterFile
        builds[$count]="$tarBall"
        ((count++))
    done
done

# Copy the builds to byss
if [ "$overallStatus" = "Success" ]; then

    echo "" >> $statusMasterFile
    echo "Link: $link" >> $statusMasterFile
    echo "" >> $statusMasterFile
    echo "Paths on byss" >> $statusMasterFile

    echo Wil copy doc and builds to byss
    rsync -avz dist-add/asp_book.pdf $user@$byss:$byssPath 2>/dev/null
    len="${#builds[@]}"
    for ((count = 0; count < len; count++)); do
        echo Copying ${builds[$count]} to $user@$byss:$byssPath
        rsync -avz ${builds[$count]} $user@$byss:$byssPath 2>/dev/null
        rm -f "${builds[$count]}" # No need to keep this around
        build=${builds[$count]}
        build=${build/asp_tarballs\//}
        echo $byssPath/$build >> $statusMasterFile
    done

    # Wipe older files on byss and gen the index for today
    rsync -avz rm_old.sh gen_index.sh $user@$byss:$byssPath 2>/dev/null
    ssh $user@$byss "$byssPath/rm_old.sh $byssPath 12" 2>/dev/null
    ssh $user@$byss "$byssPath/gen_index.sh $byssPath $version $timestamp" 2>/dev/null
fi

subject="Build $timestamp status is $overallStatus"
mailx $mailto -s "$subject" < $statusMasterFile