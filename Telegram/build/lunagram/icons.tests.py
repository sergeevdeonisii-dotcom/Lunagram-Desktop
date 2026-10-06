from pathlib import Path

from PIL import Image, ImageChops


def main():
    art = Path(__file__).resolve().parents[2] / 'Resources' / 'art'
    sizes = [16, 32, 48, 64, 128, 256, 512]
    source = Image.open(art / 'lunagram-logo-source.png').convert('RGBA')
    assert source.size == (1024, 1024), 'Keep the editable plane raster at full resolution.'
    for size in sizes:
        for suffix, side in [('', size), ('@2x', size * 2)]:
            name = f'icon{size}{suffix}.png'
            with Image.open(art / name) as actual:
                rgba = actual.convert('RGBA')
                assert rgba.size == (side, side), name
                expected = source.resize((side, side), Image.Resampling.LANCZOS)
                assert ImageChops.difference(rgba, expected).getbbox(alpha_only=False) is None, name
                assert rgba.getpixel((0, 0))[3] == 0, f'{name}: rounded transparent corner'
                assert rgba.getpixel((side // 2, side // 2))[3] == 255, f'{name}: solid centre'
    with Image.open(art / 'icon256.ico') as icon:
        assert icon.ico.sizes() == {(size, size) for size in sizes if size <= 256}
        for size in sizes:
            if size > 256:
                continue
            frame = icon.ico.getimage((size, size)).convert('RGBA')
            expected = Image.open(art / f'icon{size}.png').convert('RGBA')
            assert ImageChops.difference(frame, expected).getbbox(alpha_only=False) is None, f'ICO {size}px'
    for name, side in [('logo_256.png', 256), ('logo_256_no_margin.png', 256),
                       ('icon_round512@2x.png', 1024), ('icon_green.png', 512),
                       ('iconbig_green.png', 256)]:
        with Image.open(art / name) as actual:
            expected = source.resize((side, side), Image.Resampling.LANCZOS)
            assert ImageChops.difference(actual.convert('RGBA'), expected).getbbox(alpha_only=False) is None, name
    print('PASS: 14 PNG sizes, 6 Windows ICO frames and 5 runtime logo slots match the Luma plane source. Native shell caching still requires a live check.')


if __name__ == '__main__':
    main()
