arch-bootstrap
==============

Bootstrap a base Arch Linux system from any GNU/Linux.

Install
=======

    # install -m 755 arch-bootstrap.sh /usr/local/bin/arch-bootstrap

Examples
=========

Create a base arch distribution in directory 'myarch':

    # arch-bootstrap myarch

Usage
=====

Once the process has finished, chroot to the destination directory (default user: root/root):

    # arch-bootstrap -c myarch
    # arch-bootstrap.sh -c myarch echo "hello, world!"

License
=======

This project is licensed under the terms of the MIT license

---