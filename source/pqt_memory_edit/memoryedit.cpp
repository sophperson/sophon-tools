#include "memoryedit.h"

// 对作为命令参数内嵌的用户输入做 shell 单引号转义：
// 输入中的 ' 用 '\'' 闭合，使整段内容在远程 shell 中始终作为单个字面量，
// 防止密码等含空格/元字符的输入改写命令语义（命令注入）。
static QString
shellQuote(const QString& s) {
  return "'" + QString(s).replace("'", "'\\''") + "'";
}

MemoryEdit::MemoryEdit(QWidget* iparent) {
  parent = iparent;
  QObject::connect(
    this,
    SIGNAL(
      SI_flashInfo(MemoryEdit::memInfoStruct*, MemoryEdit::memInfoStruct*)),
    parent,
    SLOT(flashInfo(MemoryEdit::memInfoStruct*, MemoryEdit::memInfoStruct*)),
    Qt::QueuedConnection);
  QObject::connect(
    this, SIGNAL(SI_flashStatus(QString, quint64)), parent,
    SLOT(flashStatus(QString, quint64)), Qt::QueuedConnection);
  QObject::connect(
    this, SIGNAL(SI_comReturn(bool, quint64)), parent, SLOT(comReturn(bool,
        quint64)),
    Qt::QueuedConnection);
  QObject::connect(this,
    SIGNAL(SI_WarningMessage(QString, quint64)),
    parent,
    SLOT(WarningMessage(QString, quint64)), Qt::QueuedConnection);
  QObject::connect(this,
    SIGNAL(SI_returnComLog(QString, quint64)),
    parent,
    SLOT(returnComLog(QString, quint64)), Qt::QueuedConnection);
  QObject::connect(this,
    SIGNAL(SI_flashProgress(double, quint64)),
    parent,
    SLOT(flashProgress(double, quint64)), Qt::QueuedConnection);
}
MemoryEdit::~MemoryEdit() {
  this->disconnect();
}

void
MemoryEdit::run() {
  qint64 rc;
  if (com == 0)
    rc = comP();
  else if (com == 1)
    rc = comC(autoRestart);
  emit SI_CR(((rc == STATE_SUCCESS)
      || (rc == STATE_ERROR_WARNINGINF)) ? true : false);
}

int
MemoryEdit::upFile(QString filePath, QString remoteFilePath) {
  qint64 bytesRead;
  unsigned long hostaddr;
  int sock, i, auth_pw = 1;
  struct sockaddr_in sin;
  const char* fingerprint;
  LIBSSH2_SESSION* session;
  LIBSSH2_SFTP* sftp_session;
  LIBSSH2_SFTP_HANDLE* sftp_handle;
  LIBSSH2_CHANNEL* channel;
  QFile localFile(filePath);
  quint64 fileSize, trSize;
  int re = -1;
  hostaddr = inet_addr(remoteIp.toLocal8Bit());
  sin.sin_family = AF_INET;
  sin.sin_port = htons(remotePort);
  sin.sin_addr.s_addr = hostaddr;
  sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock == -1) {
    sshWarrning("failed to create socket!");
    return re;
  }
  if (::connect(sock, (struct sockaddr*)(&sin), sizeof(struct sockaddr_in)) !=
    0) {
    sshWarrning("failed to connect!");
    goto closeSocket;
  }
  qDebug("sock connected!");
  session = libssh2_session_init(); //创建一个会话实例
  if (libssh2_session_handshake(session, sock)) {
    sshWarrning("Failure establishing SSH session");
    goto freeSession;
  }
  if (libssh2_userauth_password(
      session, user.toLocal8Bit(), passwd.toLocal8Bit())) {
    sshWarrning("Authentication by password failed!");
    goto freeSession;
  }
  else
    qDebug("Authentication by password succeeded.");
  sftp_session = libssh2_sftp_init(session);
  if (!sftp_session) {
    sshWarrning("无法打开stfp");
    goto shutdown_sftp;
  }
  sftp_handle =
    libssh2_sftp_open(sftp_session,
      remoteFilePath.toLocal8Bit(),
      LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
      LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
      LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH);
  if (!sftp_handle) {
    sshWarrning("无法创建远程文件");
    goto close_sftp;
  }
  if (!localFile.open(QIODevice::ReadOnly)) {
    sshWarrning("不能打开本地文件");
    goto close_sftp;
  }
  fileSize = localFile.size();
  trSize = 0;
  while ((bytesRead = localFile.read(read_buffer, sizeof(read_buffer))) > 0) {
    qint64 bytesWrite = 0;
    while (bytesWrite != bytesRead) {
      bytesWrite += libssh2_sftp_write(sftp_handle, read_buffer + bytesWrite,
          bytesRead - bytesWrite);
      libssh2_sftp_fsync(sftp_handle);
    }
    trSize += bytesRead;
    emit SI_FP((double)trSize / fileSize);
  }
  while (0 != libssh2_sftp_fsync(sftp_handle)) {
    sshWarrning("sftp fsync失败，重试中");
    QThread::msleep(200);
  }
  re = 0;
close_sftp:
  libssh2_sftp_close(sftp_handle);
shutdown_sftp:
  libssh2_sftp_shutdown(sftp_session);
disconnectSession:
  libssh2_session_disconnect(session, "");
freeSession:
  libssh2_session_free(session);
closeSocket:
#ifdef WIN32
  closesocket(sock);
#else
  close(sock);
#endif
  return re;
}

int
MemoryEdit::downFile(QString remoteFilePath, QString localFilePath) {
  qint64 bytesRead;
  unsigned long hostaddr;
  int sock, i, auth_pw = 1;
  struct sockaddr_in sin;
  const char* fingerprint;
  LIBSSH2_SESSION* session;
  LIBSSH2_SFTP* sftp_session;
  LIBSSH2_SFTP_HANDLE* sftp_handle;
  LIBSSH2_CHANNEL* channel;
  QFile localFile(localFilePath);
  qint64 read_cnt = 0;
  int re = -1, rc;
  quint64 fileSize, trSize;
  hostaddr = inet_addr(remoteIp.toLocal8Bit());
  sin.sin_family = AF_INET;
  sin.sin_port = htons(remotePort);
  sin.sin_addr.s_addr = hostaddr;
  sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock == -1) {
    sshWarrning("failed to create socket!");
    return re;
  }
  if (::connect(sock, (struct sockaddr*)(&sin), sizeof(struct sockaddr_in)) !=
    0) {
    sshWarrning("failed to connect!");
    goto closeSocket;
  }
  qDebug("sock connected!");
  session = libssh2_session_init(); //创建一个会话实例
  if (libssh2_session_handshake(session, sock)) {
    sshWarrning("Failure establishing SSH session");
    goto freeSession;
  }
  if (libssh2_userauth_password(
      session, user.toLocal8Bit(), passwd.toLocal8Bit())) {
    sshWarrning("Authentication by password failed!");
    goto freeSession;
  }
  else
    qDebug("Authentication by password succeeded.");
  sftp_session = libssh2_sftp_init(session);
  if (!sftp_session) {
    sshWarrning("无法打开stfp");
    goto shutdown_sftp;
  }
  LIBSSH2_SFTP_ATTRIBUTES attributes;
  rc =
    libssh2_sftp_stat(sftp_session, remoteFilePath.toLocal8Bit(), &attributes);
  if (rc != 0) {
    sshWarrning(QString("Failed to get file attributes: %1").arg(rc));
    goto shutdown_sftp;
  }
  sftp_handle = libssh2_sftp_open(
      sftp_session, remoteFilePath.toLocal8Bit(), LIBSSH2_FXF_READ, 0);
  if (!sftp_handle) {
    sshWarrning("无法打开远程文件");
    goto close_sftp;
  }
  if (!localFile.open(QIODevice::WriteOnly)) {
    sshWarrning("不能打开本地文件");
    goto close_sftp;
  }
  while (0 != libssh2_sftp_fsync(sftp_handle)) {
    sshWarrning("sftp fsync失败，重试中");
    QThread::msleep(200);
  }
  fileSize = attributes.filesize;
  trSize = 0;
  while (1) {
    bytesRead =
      libssh2_sftp_read(sftp_handle, read_buffer, sizeof(read_buffer));
    if (bytesRead == LIBSSH2_ERROR_EAGAIN) {
      QThread::msleep(100);
      continue;
    }
    else if (bytesRead < 0)
      goto close_sftp;
    else if (bytesRead == 0)
      break;
    else
      localFile.write(read_buffer, bytesRead);
    trSize += bytesRead;
    emit SI_FP((double)trSize / fileSize);
  }
  re = 0;
close_sftp:
  libssh2_sftp_close(sftp_handle);
shutdown_sftp:
  libssh2_sftp_shutdown(sftp_session);
disconnectSession:
  libssh2_session_disconnect(session, "");
freeSession:
  libssh2_session_free(session);
closeSocket:
#ifdef WIN32
  closesocket(sock);
#else
  close(sock);
#endif
  return re;
}

int
MemoryEdit::sendCommend(QString sendInfo, QString& reInfo) {
  qint64 bytesRead;
  unsigned long hostaddr;
  int sock, i, auth_pw = 1;
  struct sockaddr_in sin;
  const char* fingerprint;
  LIBSSH2_SESSION* session;
  LIBSSH2_SFTP* sftp_session;
  LIBSSH2_SFTP_HANDLE* sftp_handle;
  LIBSSH2_CHANNEL* channel;
  int re = -1, rc;
  hostaddr = inet_addr(remoteIp.toLocal8Bit());
  sin.sin_family = AF_INET;
  sin.sin_port = htons(remotePort);
  sin.sin_addr.s_addr = hostaddr;
  sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock == -1) {
    sshWarrning("failed to create socket!");
    return re;
  }
  if (::connect(sock, (struct sockaddr*)(&sin), sizeof(struct sockaddr_in)) !=
    0) {
    sshWarrning("failed to connect!");
    goto closeSocket;
  }
  qDebug("sock connected!");
  session = libssh2_session_init(); //创建一个会话实例
  if (libssh2_session_handshake(session, sock)) {
    sshWarrning("Failure establishing SSH session");
    goto freeSession;
  }
  if (libssh2_userauth_password(
      session, user.toLocal8Bit(), passwd.toLocal8Bit())) {
    sshWarrning("Authentication by password failed!");
    goto freeSession;
  }
  else
    qDebug("Authentication by password succeeded.");
  channel = libssh2_channel_open_session(session);
  if (!channel) {
    sshWarrning("无法打开会话");
    goto disconnectSession;
  }
  libssh2_channel_set_blocking(channel, 1);
  rc = libssh2_channel_exec(channel, sendInfo.toLocal8Bit());
  if (rc != 0) {
    sshWarrning("发送指令失败 rm -rf /data/.memedit");
    goto disconnectSession;
  }
  reInfo.clear();
  while ((bytesRead = libssh2_channel_read(
          channel, read_buffer, sizeof(read_buffer) - 1)) > 0) {
    read_buffer[bytesRead] = '\0'; // 将读取的数据末尾添加终止符
    // 处理返回的数据，可以打印或存储等操作
    reInfo.append(read_buffer);
  }
  reInfo.replace("\\n", "\n");
  re = 0;
disconnectSession:
  libssh2_session_disconnect(session, "");
freeSession:
  libssh2_session_free(session);
closeSocket:
#ifdef WIN32
  closesocket(sock);
#else
  close(sock);
#endif
  return re;
}

int
MemoryEdit::comP() {
  qint64 rc;
  QString currentDateTimeString =
    QDateTime::currentDateTime().toString("yyyy_MM_dd_hh_mm_ss");
  const QString default_file =
    "memory_edit_p_" + remoteIp + "_" + QString::number(remotePort) + "_" +
    currentDateTimeString +
    ".tgz";
  QString rex;
  const QString sudoAu("echo " + shellQuote(passwd) + " | sudo -S");
  const QString localFile("://mem_edit_file");
  const QString remoteFile("/data/.memedit/mem_edit.tar.xz");
  const QString
  com1 = QString("%1 rm -rf /data/.memedit && %1 mkdir -p /data/.memedit && %1 "
      "ls -lah /data/.memedit && %1 chmod 777 -R /data/.memedit").arg(sudoAu);
  const QString com2("tar -xaf " + remoteFile + " -C /data/.memedit/");
  const QString
  com3("pushd /data/.memedit/memory_edit;chmod +x memory_edit.sh; echo "
    + shellQuote(passwd) + " | sudo -S ./memory_edit.sh -p | tee memory_edit_p.log");
  QStringList com3RexList;
  const QString com4("pushd /data/.memedit; tar -caf " + default_file +
    " memory_edit");
  const QString com5("rm -rf /data/.memedit");
  QString localFilePath = localDir.filePath(default_file);
  bool ok;
  emit SI_FS("正在进行前置准备，请稍等");
  emit SSH_CHECK(rc = STATE_ERROR_SSH, sendCommend(com1, rex), 0, return rc);
  qDebug() << "sendCommend com1: " << rex;
  emit SI_RC(
    QString("%1\n%2\n%3").arg(currentDateTimeString, com1, rex));
  emit SI_FS("正在上传资源文件，请稍等");
  emit SFTP_CHECK(rc = STATE_ERROR_SFTP, upFile(localFile, remoteFile), 0,
    return rc);
  rex.clear();
  emit SI_FS("正在执行获取内存布局操作，请稍等");
  emit SSH_CHECK(rc = STATE_ERROR_SSH, sendCommend(com2, rex), 0, goto del_file;);
  qDebug() << "sendCommend com2: " << rex;
  emit SI_RC(
    QString("%1\n%2\n%3").arg(currentDateTimeString, com2, rex));
  emit SSH_CHECK(rc = STATE_ERROR_SSH, sendCommend(com3, rex), 0, goto del_file;);
  qDebug() << "sendCommend com3: " << rex;
  emit SI_RC(
    QString("%1\n%2\n%3").arg(currentDateTimeString, com3, rex));
  if (rex.contains("ERROR", Qt::CaseInsensitive)) {
    emit SI_WM(
      QString(
        "获取目标信息过程中发生了错误，\n%1\n请检查返回的log和之后保存的压缩包")
      .arg(rex));
    rc = STATE_ERROR_ERRORINF;
    goto down_file;
  }
  if (rex.contains("warrning", Qt::CaseInsensitive)) {
    emit SI_WM(
      QString(
        "获取目标信息过程中发生了警告，\n%1\n如果您认为该情况合理，请忽视")
      .arg(rex));
    rc = STATE_ERROR_WARNINGINF;
  }
  com3RexList = rex.split("\n");
  foreach (auto item, com3RexList) {
    if (item.contains("Info: max ", Qt::CaseSensitive)) {
      QStringList items = item.split(" ");
      quint64 size = items.at(4).toULongLong(&ok, 16) / 1024 / 1024;
      flashMax(items.at(2), size);
    }
    if (item.contains("Info: now ", Qt::CaseSensitive)) {
      QStringList items = item.split(" ");
      quint64 size = items.at(4).toULongLong(&ok, 16) / 1024 / 1024;
      flashNow(items.at(2), size);
    }
  }
  emit SI_flashInfo(&memMax, &memNow);
  rc = STATE_SUCCESS;
down_file:
  emit SI_FS("正在打包远程执行后的过程文件，请稍等");
  emit SSH_CHECK(, sendCommend(com4, rex), 0, goto del_file);
  emit SI_FS("正在下载远程执行后的过程文件" + default_file
    +
    "，请稍等");
  emit SFTP_CHECK(, downFile("/data/.memedit/" + default_file,
      localFilePath), 0,
    ;);
del_file:
  emit SSH_CHECK(, sendCommend(com5, rex), 0, return rc);
  if (rc == STATE_SUCCESS)
    emit SI_FS("获取内存布局操作执行完成");
  return rc;
}

int
MemoryEdit::comC(bool autoRestart) {
  qint64 rc;
  QString rex;
  QString currentDateTimeString =
    QDateTime::currentDateTime().toString("yyyy_MM_dd_hh_mm_ss");
  const QString default_file =
    "memory_edit_c_" + remoteIp + "_" + QString::number(remotePort) + "_" +
    currentDateTimeString +
    ".tgz";
  QString localFile("://mem_edit_file");
  QString remoteFile("/data/.memedit/mem_edit.tar.xz");
  const QString sudoAu("echo " + shellQuote(passwd) + " | sudo -S");
  const QString com1 =
    QString("%1 rm -rf /data/.memedit && %1 mkdir -p /data/.memedit && %1 "
      "ls -lah /data/.memedit && %1 chmod 777 -R /data/.memedit").arg(sudoAu);
  const QString com2("tar -xaf " + remoteFile + " -C /data/.memedit/");
  const QString sizeStr =
    QString(" -npu 0x%1 -vpu 0x%2 -vpp 0x%3")
    .arg(
      QString::number(quint64(memSet.npu_mem) * 1024 * 1024, 16).toUpper(),
      QString::number(quint64(memSet.vpu_mem) * 1024 * 1024, 16).toUpper(),
      QString::number(quint64(memSet.vpp_mem) * 1024 * 1024, 16).toUpper());
  const QString
  com3("pushd /data/.memedit/memory_edit; chmod +x memory_edit.sh; echo "
    + shellQuote(passwd) + " | sudo -S ./memory_edit.sh -c" +
    sizeStr + " | tee memory_edit_c.log");
  const QString com4("pushd /data/.memedit/memory_edit; echo " + shellQuote(passwd) +
    " | sudo -S cp *.itb /boot; sync");
  const QString com5("pushd /data/.memedit; tar -caf " + default_file +
    " memory_edit");
  const QString com6("rm -rf /data/.memedit");
  const QString com7("echo " + shellQuote(passwd) + " | sudo -S reboot");
  QString localFilePath = localDir.filePath(default_file);
  bool ok;
  emit SI_FS("正在进行前置准备，请稍等");
  emit SSH_CHECK(rc = STATE_ERROR_SSH, sendCommend(com1, rex), 0, return rc);
  qDebug() << "sendCommend com1: " << rex;
  emit SI_RC(
    QString("%1\n%2\n%3").arg(currentDateTimeString, com1, rex));
  emit SI_FS("正在上传资源文件，请稍等");
  emit SFTP_CHECK(rc = STATE_ERROR_SFTP, upFile(localFile, remoteFile), 0,
    return rc);
  rex.clear();
  emit SI_FS("正在执行修改内存布局操作，请稍等");
  emit SSH_CHECK(rc = STATE_ERROR_SSH, sendCommend(com2, rex), 0, goto del_file;);
  qDebug() << "sendCommend com2: " << rex;
  emit SI_RC(
    QString("%1\n%2\n%3").arg(currentDateTimeString, com2, rex));
  emit SSH_CHECK(rc = STATE_ERROR_SSH, sendCommend(com3, rex), 0, return rc);
  qDebug() << "sendCommend com3: " << rex;
  emit SI_RC(
    QString("%1\n%2\n%3").arg(currentDateTimeString, com3, rex));
  if (rex.contains("ERROR", Qt::CaseInsensitive)) {
    emit SI_WM(
      QString("配置过程中发生了错误，\n%1\n请检查返回的log和之后保存的压缩包")
      .arg(rex));
    rc = STATE_ERROR_ERRORINF;
    goto down_file;
  }
  if (rex.contains("warrning", Qt::CaseInsensitive)) {
    emit SI_WM(
      QString("配置过程中发生了警告，\n%1\n如果您认为该情况合理，请忽视")
      .arg(rex));
    rc = STATE_ERROR_WARNINGINF;
  }
  sendCommend(com4, rex);
  qDebug() << "sendCommend com4: " << rex;
  emit SI_RC(
    QString("%1\n%2\n%3").arg(currentDateTimeString, com4, rex));
  rc = STATE_SUCCESS;
down_file:
  emit SI_FS("正在打包远程执行后的过程文件，请稍等");
  emit SSH_CHECK(, sendCommend(com5, rex), 0, goto del_file);
  emit SI_FS("正在下载远程执行后的过程文件" + default_file
    +
    "，请稍等");
  emit SFTP_CHECK(,
    downFile("/data/.memedit/" + default_file, localFilePath), 0,
    ;);
del_file:
  emit SSH_CHECK(, sendCommend(com6, rex), 0, return rc);
  if (rc == STATE_SUCCESS) {
    if (autoRestart) {
      emit SSH_CHECK(, sendCommend(com7, rex), 0, return rc);
      emit SI_FS("修改内存布局操作执行完成，将自动重启");
    }
    else {
      emit SI_FS("修改内存布局操作执行完成，请确定log正确，保存工作后手动"
        "重启远程端以生效修改");
    }
  }
  return rc;
}
void
MemoryEdit::flashMax(QString memType, quint64 maxSize) {
  if (memType == "npu")
    memMax.npu_mem = maxSize;
  else if (memType == "vpu")
    memMax.vpu_mem = maxSize;
  else if (memType == "vpp")
    memMax.vpp_mem = maxSize;
  else if (memType == "npu+vpp") {
    memMax.vpu_mem = maxSize;
    memMax.vpu_mem_to_npuvpp_flag = true;
  }
}

void
MemoryEdit::flashNow(QString memType, quint64 nowSize) {
  if (memType == "npu")
    memNow.npu_mem = nowSize;
  else if (memType == "vpu")
    memNow.vpu_mem = nowSize;
  else if (memType == "vpp")
    memNow.vpp_mem = nowSize;
}
