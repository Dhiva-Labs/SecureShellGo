### Security

- An AI Bridge read on a server whose login shell is fish could be made to run text the app did not intend, through a file name, folder or pattern that contained a backslash. Commands are now quoted so that no login shell (fish included) reads a backslash as anything but a backslash.
