# Constructors copy queue of Constructors

**Description:** Instead of guarding a Constructors, they will just copy the orders.

This script will make it so when make a builder [ALT]+Guard a builder, it will copy their command queue (so it will build all the same things). This mean you can take the "original"  builder away from the building, without destroying the whole queue for all other builders. 

You can also [CTRL]+Guard to "shuffle" the order of the commands, so you can make sure large projects are distrubuted (randomly, instead of the META+Right Click structered) way.

It is more efficient to copy all of the building commands so each builder will move directly to the build site, instead try to follow the builder to the build site. It also helps to start multiple sites at once, so your Nanos can quickly finish them without waiting for 5 bots to slowly move to the next one.

TODO: 
Also make factories copy eachother on Guard

- **Author:** uBdead
- **Date:** Jul 18 2025
- **License:** GPL v2 or later

