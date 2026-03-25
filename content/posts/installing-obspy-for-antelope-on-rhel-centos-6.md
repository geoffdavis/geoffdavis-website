+++
date = '2014-08-11T12:37:34-07:00'
title = 'Installing Obspy for Antelope 5.4 on RHEL/CentOS 6'
tags = ['antelope', 'linux', 'sysadmin', 'python', 'seismology']
+++

## Background

The [obspy framework](http://obspy.org) is a set of Python libraries for observational seismology. It includes a number of routines to retrieve and process seismic data in a variety of formats.

[Antelope](http://brtt.com) is a commercial data acquisition and processing system for environmental data, with a heavy emphasis on seismic data. Many regional seismic networks use Antelope to acquire, process, and exchange seismic data. Starting with version 5.2, it has included Python bindings for many of it's core routines for databases and real-time data.

The Obspy framework combined with Antelope represents a best-of-breed combination of interoperability with other seismic data formats and rapid application development. However, due to possible licensing restrictions, BRTT does not currently distribute Obspy.

BRTT ships their own distribution of Python with Antelope, so just installing the system packages for `scipy` and `numpy` included with RHEL is not an acceptable solution. You would not get access to the Antelope routines from Obspy installed in this fashion.

Obspy has a number of dependencies, some of which conflict with libraries shipped with Antelope. In particular, the Numpy is not configured with some required external dependencies such as `BLAS` and `LAPACK` that `Scipy` (another `Obspy` dependency) requires.

Thus, there are two ways to go about working around this issue:

- Install a newer version of Numpy or overwrite the existing numpy library in the `/opt/antelope/python2.7.6/site-packages` directly
- Install into a different `site-packages` directory outside of the BRTT-supplied directories.

The first approach, putting all of the new packages including this upgraded `numpy` module in the BRTT `site-packages` directory, introduces the possibility of compatibility issues with BRTT-supplied code (such as `orbrtd`) that may depend on their version of `numpy` (1.7.1). In practice there haven't been any reported compatibility problems, but it's best to not step on BRTT's supported version of the software any more than you have to.

The second approach requires a bit more work on your end, but it ensures that BRTT-written programs will not have compatibility issues with any upgraded libraries.

My facility uses the second approach, but it's tied to our own `/opt/anf` overlay to `/opt/antelope`. If you are sharing code with a number of users at a site, setting up an overlay tree for Antelope is a really good way to keep your code in revision control and provide it to all users on your system without modifying the BRTT `/opt/antelope` tree extensively. See the utility `build_sourcetree` in the [Antelope contributed software repository](https://github.com/antelopeusersgroup/antelope_contrib) on how to get off the ground with your own overlay.

For the purposes of this installation, I will assume that your site does not have a `build_sourcetree`-style overlay, and that you want obspy to be available to all users on your system. Thus, we will choose the directory `/opt/antelope/local/lib/python2.7` as a place to install the obspy packages, and the binaries will go in `/opt/antelope/local/bin`.

## Prerequisites

1. A working installation of Antelope 5.4 or later
2. ... on a RHEL or CentOS 6 OS
3. ... with the development tools installed (`yum -y groupinstall "Development tools"`)
4. Your shell environment must be set up with the Antelope environment - For Bourne-style shells, run `source /opt/antelope/5.4/setup.sh`

The instructions below assume you are using Bash or another Bourne-compatible shell. There's no reason this wouldn't work in CSH, but you'll need to translate any environment variable commands to their Csh-equivalent yourself.

## Installation

## Step 0: Verify your Antelope environment is set up correctly

Run this command:

```bash
[[ -z "$ANTELOPE" ]] && echo "ANTELOPE ENVIRONMENT IS NOT SET CORRECTLY" || echo Antelope is OK
```

If that doesn't come back with "Antelope is OK", you need to source the Antelope environment

Now, run this command:

```bash
which easy_install | grep antelope || echo "You're not using the right easy_install"
```

If that complains that you're not using the right `easy_install`, your path may be messed up. *Make sure that the Antelope Python path comes before any other `PATH` statements.*

## Step 1: Install system library dependencies

```bash
yum install -y lapack-devel blas-devel
```

## Step 2: Create your local Python package tree and add it to your PYTHONPATH temporarily

```bash
pymoddir=/opt/antelope/local/lib/python$(getid python_mainversion)
bindir=/opt/antelope/local/bin
export PYTHONPATH=$pymoddir
mkdir -p $pymoddir
mkdir -p $bindir
export EASY_INSTALL_ARGS="-d $pymoddir -s $bindir -N"
unset pymodir
unset bindir
```

There's a couple of things going on in that blob of shell commands that are worth noting. First is the usage of the Antelope command `getid`. This program allows you to get a bunch of configuration information from Antelope, including the Python version in use. Run the command `getid -a` for a list of all of the information that `getid` can report.

Note that we could have also gotten the python major and minor version (python\_mainversion above) by running a python one-liner: `python -c 'import sys; sys.version[:3]'`

Secondly, the `EASY_INSTALL_ARGS` variable is being set just to save us some typing in later commands.

Finally, unless we set `PYTHON_PATH` temporarily, `easy_install` will complain that the directory we are trying to install modules into is not part of the Python search path and will refuse to run.

## Step 3: Install numpy

The latest version of `numpy` as of this writing (*1.8.0*) has a bug with it's `f2py` code that prevents Scipy from working properly. **Use *1.7.2* instead.**

If all goes right, the numpy installer will find `BLAS` and `LAPACK` and link against them. You can safely ignore any warnings about [Atlas](http://math-atlas.sourceforge.net/), unless you feel that you will need the *Atlas* routines.

```bash
easy_install ${EASY_INSTALL_ARGS} numpy==1.7.2
```

## Step 4: Install scipy

Scipy's installer bugs out if you don't explicitly set the `CC` and `CXX` variables.

```bash
CC=/usr/bin/gcc CXX=/usr/bin/g++ easy_install ${EASY_INSTALL_ARGS} scipy
```

## Step 5: Install a couple of other dependencies

You'll also need `lxml`, `suds`, and `sqlalchemy`.

```bash
easy_install ${EASY_INSTALL_ARGS} lxml
easy_install ${EASY_INSTALL_ARGS} suds
easy_install ${EASY_INSTALL_ARGS} sqlalchemy
```

## Step 6: Install obspy itself

```bash
easy_install ${EASY_INSTALL_ARGS} obspy
```

## Usage

In order to actually use the obspy libraries in code, you'll need to remember to include the `/opt/antelope/local` tree in your Python search path. There are a couple of ways to make this work. The best way (which ensures that nothing weird will happen with core BRTT programs) is to explicitly modify the python search path in your code itself.

If you set your `PYTHONPATH` to `/opt/antelope/local/lib/python2.7`, things will probably work but you run the risk of odd behavior with core Antelope programs.

Thus, it's recommended that each program is prefixed with a line like

```python
import site; import sys; site.addsitedir('/opt/antelope/local/lib/python' + sys.version[:3])
```

It's important to use `site.addsitedir` instead of `sys.path.append` because the latter doesn't evaluate `easy_install.pth`, and thus Python won't see any of the new modules you installed.

## In iPython or as a standalone script

A full pasteable blurb that should get iPython ready to use Obspy and Antelope looks like this:

```python
import os
import sys
import site

import signal

signal.signal(signal.SIGINT, signal.SIG_DFL)

sys.path.append(os.environ['ANTELOPE'] + "/data/python")
site.addsitedir('/opt/antelope/local/lib/python' + sys.version[:3])
```

## As an `.xpy` file

If you use the ANTELOPEMAKE structure to build Antelope programs, there is a file type called `.xpy` that will configure your script with a preamble similar to the iPython blurb above, *except it does not include the last line.*

Every `xpy` file that makes use of the `obspy` code will need the following line pre-pended to the file before any `obspy` module imports are made (note that the standard xpy header already imports `os` and `sys` for you):

```python
site.addsitedir('/opt/antelope/local/lib/python' + sys.version[:3])
```

The following `example.xpy` will get "compiled" into a script named `example`:

```python
site.addsitedir('/opt/antelope/local/lib/python' + sys.version[:3])

import numpy as np
import matplotlib.pyplot as plt
from obspy.core import UTCDateTime
from obspy.arclink import Client
from obspy.signal import cornFreq2Paz, seisSim

client = Client(user='test@obspy.de')

t = UTCDateTime('2009-08-24 00:20:03')
st = client.getWaveform('BW', 'RJOB', '', 'EHZ', t, t + 30)
pas = client.getPAZ('BW', 'RJOB', '', 'EHZ', t)

# 1Hz instrument
one_hertz = cornFreq2Paz(1.0)

# Correct for frequency response of the instrument
res = res / paz['sensitivity']

# Plot the seismograms
sec = np.arange(len(res)) / st[0].stats.sampling_rate

plt.subplot(211)
plt.plot(sec, st[0].data, 'k')
plt.title("%s %s" % (st[0].stats.station, t))
plt.ylabel('STS-2')

plt.subplot(212)
plt.plot(sec, res, 'k')
plt.xlabel('Time [s]')
plt.ylabel('1Hz CornerFrequency')

plt.show()
```
