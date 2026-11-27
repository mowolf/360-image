# App icon

`AppIcon.png` is concept **C · Lens Globe**: a camera lens whose front glass element shows a
globe grid, plus the app's orange capture dot. It is rendered procedurally in Liquid Glass style
by `concepts.py` (`lens_globe`), using the small SDF renderer in `glass.py`.

```sh
cd scripts/icon && python3 -c "import concepts; concepts.lens_globe('AppIcon.png')"
cp AppIcon.png ../../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```
