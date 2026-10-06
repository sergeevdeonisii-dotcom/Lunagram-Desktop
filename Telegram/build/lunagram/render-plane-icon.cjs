const path = require('node:path');
const sharp = require('sharp');

const art = path.resolve(__dirname, '../../Resources/art');
sharp(path.join(art, 'lunagram-logo-source.svg'))
  .resize(1024, 1024)
  .png()
  .toFile(path.join(art, 'lunagram-logo-source.png'))
  .then(() => console.log('Rendered the existing Luma Navy paper plane at 1024px. Run convert-icons.py to refresh the native icon slots.'))
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
