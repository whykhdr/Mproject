const express = require('express');
const { exec } = require('child_process');
const app = express();
const port = 3000;

app.use(express.json());

// Middleware sederhana untuk autentikasi basic
const auth = (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || authHeader !== 'Basic cGFuZWw6cGFuZWwxMjM=') { // "panel:panel123" base64
    res.setHeader('WWW-Authenticate', 'Basic realm="Panel Login"');
    return res.status(401).send('Authentication required.');
  }
  next();
};

app.post('/api/create-ssh', auth, (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).send('Username dan password wajib diisi');
  }

  // Periksa apakah user sudah ada
  const checkUser Cmd = `id -u ${username}`;
  exec(checkUser Cmd, (errorCheck) => {
    if (!errorCheck) {
      return res.status(400).send('User  sudah ada.');
    }
    // Perintah buat user
    const cmd = `useradd -m ${username} -s /bin/bash && echo "${username}:${password}" | chpasswd && passwd -e ${username}`;
    exec(cmd, (error, stdout, stderr) => {
      if (error) {
        return res.status(500).send(`Error: ${stderr}`);
      }
      res.send(`User  ${username} berhasil dibuat.`);
    });
  });
});

app.get('/api/status', (req, res) => {
  res.json({ status: "Panel VPS berjalan" });
});

app.listen(port, () => {
  console.log(`Server berjalan di http://localhost:${port}`);
});
