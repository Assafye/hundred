const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');

const emails = [
  'assafyeho@gmail.com',
  'israel@gmail.com',
  'liat@gmail.com',
  'adi@gmail.com',
  'shahar@gmail.com',
  'danadana@gmail.com',
];

initializeApp({ projectId: 'hundred-6c680' });

async function main() {
  const auth = getAuth();
  let failed = false;

  for (const email of emails) {
    try {
      const user = await auth.getUserByEmail(email);
      const updated = await auth.updateUser(user.uid, {
        emailVerified: true,
      });
      console.log(
        'OK ' + email + ' -> uid=' + updated.uid + ' verified=' + updated.emailVerified,
      );
    } catch (error) {
      failed = true;
      console.error(
        'ERR ' +
          email +
          ' -> code=' +
          (error.code || 'unknown') +
          ' message=' +
          (error.message || String(error)),
      );
    }
  }

  if (failed) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error('FATAL', error);
  process.exit(1);
});