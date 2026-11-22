# lgtv-control
Simple app for MacOS to control LG TVs used as monitors

Created to solve my own problem of more seamless use of LG OLED TV's that I use for monitors for my Macs.

Just build the app, and put under Applications, and have it auto start when you login.


Features:
 - Will capture volume controls on MacOS and control the volume on the TVs.
 - Will control any number of TVs you want, that are connected to the network (they need an IP, and if you add the MAC address it can also do wake on lan), you need to both enable "Mobile Control" on the TV's and then pair with each TV from the App.

Missing:
 - It will only run as a user account (not system service), future verisons might be built to run as a system service so that it starts before any user logs in.