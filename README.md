# Sedulous

### Instructions
1. Manually copy ```Sources/Dependencies/SDL2/Libs``` to ```.build/debug```
2. Ensure CSDL2/include is passed as an include dir to the C compiler like:
   ```swift run Sandbox -Xcc -IPath\\To\\Sources\\Dependencies\\SDL2\\Sources\\CSDL2\\include```
   where ```Path\\To``` is the absolute root path of the checked out repo
