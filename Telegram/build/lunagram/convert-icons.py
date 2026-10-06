import argparse
from pathlib import Path

from PIL import Image


def main():
    resources = Path(__file__).resolve().parents[2] / 'Resources' / 'art'
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=resources / 'lunagram-logo-source.png')
    args = parser.parse_args()
    with Image.open(args.source) as source:
        image = source.convert('RGBA')
    if image.width != image.height:
        raise ValueError('The approved application artwork must be square.')
    image.save(resources / 'lunagram-logo-source.png')
    sizes = [16, 32, 48, 64, 128, 256, 512]
    for size in sizes:
        image.resize((size, size), Image.Resampling.LANCZOS).save(resources / f'icon{size}.png')
        image.resize((size * 2, size * 2), Image.Resampling.LANCZOS).save(resources / f'icon{size}@2x.png')
    image.save(resources / 'icon256.ico', format='ICO', sizes=[(size, size) for size in sizes if size <= 256])
    image.resize((256, 256), Image.Resampling.LANCZOS).save(resources / 'logo_256.png')
    image.resize((256, 256), Image.Resampling.LANCZOS).save(resources / 'logo_256_no_margin.png')
    image.resize((1024, 1024), Image.Resampling.LANCZOS).save(resources / 'icon_round512@2x.png')
    image.resize((512, 512), Image.Resampling.LANCZOS).save(resources / 'icon_green.png')
    image.resize((256, 256), Image.Resampling.LANCZOS).save(resources / 'iconbig_green.png')
    print('Converted approved Lunagram artwork into native Windows ICO and PNG application icon slots.')


if __name__ == '__main__':
    main()
