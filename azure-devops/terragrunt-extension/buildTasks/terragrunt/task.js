const tl = require('azure-pipelines-task-lib/task');
const cp = require('child_process');
const os = require('os');
const path = require('path');

async function run() {
  try {
    const install = tl.getBoolInput('install', false);
    const command = tl.getInput('command', true) || 'apply';
    const extraArgs = tl.getInput('extraArgs', false) || '';
    const workingDirectory = tl.getPathInput('workingDirectory', false) || tl.getVariable('Build.SourcesDirectory') || process.cwd();

    tl.debug(`install=${install}, command=${command}, extraArgs=${extraArgs}, cwd=${workingDirectory}`);

    let terragruntPath = 'terragrunt';

    if (install) {
      tl.debug('Ensuring terragrunt is installed...');
      terragruntPath = await ensureTerragrunt(workingDirectory);
      tl.debug(`terragruntPath=${terragruntPath}`);
    }

    const args = [command];
    if (extraArgs && extraArgs.trim().length > 0) {
      // naive split: allow users to provide already-quoted args
      args.push(...extraArgs.match(/(?:[^"\s]+|"[^"]*")+/g) || []);
    }

    tl._writeLine(`Running: ${terragruntPath} ${args.join(' ')}`);

    const res = cp.spawnSync(terragruntPath, args, { cwd: workingDirectory, stdio: 'inherit', shell: true });
    if (res.error) {
      tl.setResult(tl.TaskResult.Failed, `Failed to run terragrunt: ${res.error.message}`);
      return;
    }

    if (res.status !== 0) {
      tl.setResult(tl.TaskResult.Failed, `Terragrunt exited with code ${res.status}`);
      return;
    }

    tl.setResult(tl.TaskResult.Succeeded, 'Terragrunt completed');
  }
  catch (err) {
    tl.setResult(tl.TaskResult.Failed, err.message);
  }
}

async function ensureTerragrunt(cwd) {
  // Try to find in PATH
  try {
    const which = process.platform === 'win32' ? 'where' : 'which';
    const found = cp.execSync(`${which} terragrunt`, { encoding: 'utf8' }).trim();
    if (found) return 'terragrunt';
  } catch {}

  // Not found: install to agent tools dir
  const toolsDir = process.env['AGENT_TOOLSDIRECTORY'] || path.join(os.homedir(), '.tools');
  const binPath = path.join(toolsDir, 'terragrunt');

  try {
    // Download latest release binary for platform
    const platform = process.platform;
    let dlUrl = null;
    if (platform === 'linux') dlUrl = 'https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_linux_amd64';
    else if (platform === 'darwin') dlUrl = 'https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_darwin_amd64';
    else if (platform === 'win32') dlUrl = 'https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_windows_amd64.exe';

    if (!dlUrl) throw new Error('Unsupported platform for auto-install');

    tl._writeLine(`Downloading terragrunt from ${dlUrl} ...`);
    cp.execSync(`curl -sL -o ${binPath} ${dlUrl}`);
    cp.execSync(`chmod +x ${binPath}`);

    return binPath;
  } catch (err) {
    tl.warning('Automatic install failed; ensure terragrunt is available on the agent PATH');
    return 'terragrunt';
  }
}

run();
