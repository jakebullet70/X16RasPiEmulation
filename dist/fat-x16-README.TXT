COMMANDER X16 - YOUR PROGRAMS GO IN HERE
========================================

This folder is the one place on the SD card you can reach from a normal
computer, and everything you put in it shows up on the Commander X16.

Copy your .PRG and .BAS files straight into this folder, eject the card
properly, put it back in the Pi and switch on.


TO USE THEM ON THE X16
----------------------

At the READY. prompt, type:

    @CD:MYFILES            (go into this folder)
    @$                     (list what's in it)
    LOAD"NAME.PRG",8       (load one - the quotes matter)
    RUN                    (start it)

Or load it in one step without changing folder:

    LOAD"MYFILES/NAME.PRG",8
    RUN

To get back to the main collection that came with the machine:

    @CD:..
    @$


SAVING YOUR OWN WORK
--------------------

It works in both directions. If you write a program on the X16 and save it
while you are in this folder:

    @CD:MYFILES
    SAVE"MYNAME.PRG",8

...the file appears in this folder, so you can copy it off to your computer
next time you take the card out. That is the only folder your PC can see, so
save here if you want to keep something.


THINGS WORTH KNOWING
--------------------

* Names are shown in capitals on the X16. Keep filenames short and simple -
  letters, numbers and a dot. Avoid spaces and accented characters.

* This drive is small compared to the whole card. It is sized for your own
  programs, not for a huge collection. The machine already comes with a large
  library, which lives elsewhere on the card and appears one level up.

* Windows may pop up a message offering to format or repair the card when you
  insert it. Always say no / cancel. Windows can only read this one small
  drive and does not understand the rest of the card - that is normal and
  nothing is wrong.

* Always eject the card properly before pulling it out, or the files you just
  copied may not actually be written.
