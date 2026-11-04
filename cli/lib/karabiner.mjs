import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

export const TRIGGER_MODE_KEYBOARD = 'keyboard';
export const TRIGGER_MODE_KEYBOARD_DJI = 'keyboard+dji';

export const MANAGED_DEVICE = Object.freeze({
	identifiers: {
		is_consumer: true,
		product_id: 16401,
		vendor_id: 11427,
	},
	ignore: false,
	ignore_vendor_events: true,
});

export const MANAGED_HEADSET_FALLBACK_DEVICE = Object.freeze({
	identifiers: {
		is_consumer: true,
	},
	ignore: false,
});

export const MANAGED_DEVICES = Object.freeze([MANAGED_DEVICE, MANAGED_HEADSET_FALLBACK_DEVICE]);

const LEGACY_MANAGED_SCRIPT_COMMAND_PATH = '~/.config/karabiner/scripts/dictation-enter.sh';
const MANAGED_RECORDER_COMMAND_PATH = '~/.config/karabiner/scripts/speek-recorder';
const MANAGED_SPEEK_COMMAND_PATH = '~/.config/karabiner/scripts/speek-command';
const MANAGED_COMMAND_PATHS = Object.freeze([
	LEGACY_MANAGED_SCRIPT_COMMAND_PATH,
	MANAGED_RECORDER_COMMAND_PATH,
	MANAGED_SPEEK_COMMAND_PATH,
]);
const MANAGED_COMMAND_PATH_SUFFIXES = Object.freeze([
	'/.config/karabiner/scripts/dictation-enter.sh',
	'/.config/karabiner/scripts/speek-recorder',
	'/.config/karabiner/scripts/speek-command',
]);
const LEGACY_MANAGED_RULE_DESCRIPTIONS = new Set([
	'Fn dictation toggle + confirm/preconfirm to send Enter',
]);

function sortValue(value) {
	if (Array.isArray(value)) {
		return value.map(sortValue);
	}
	if (value && typeof value === 'object') {
		return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortValue(value[key])]));
	}
	return value;
}

function stableStringify(value) {
	return JSON.stringify(sortValue(value));
}

function ensureProfileArrays(profile) {
	profile.complex_modifications ??= {};
	profile.complex_modifications.rules ??= [];
	profile.devices ??= [];
	return profile;
}

function identifiersEqual(left = {}, right = {}) {
	const leftKeys = Object.keys(left).sort();
	const rightKeys = Object.keys(right).sort();
	return (
		leftKeys.length === rightKeys.length &&
		leftKeys.every((key, index) => key === rightKeys[index] && left[key] === right[key])
	);
}

function matchManagedDevice(device) {
	return MANAGED_DEVICES.some((managedDevice) =>
		identifiersEqual(device?.identifiers, managedDevice.identifiers),
	);
}

function valueContainsManagedScriptCommand(value) {
	if (Array.isArray(value)) {
		return value.some((item) => valueContainsManagedScriptCommand(item));
	}
	if (!value || typeof value !== 'object') {
		return false;
	}
	if (
		typeof value.shell_command === 'string' &&
		(
			MANAGED_COMMAND_PATHS.some((commandPath) => value.shell_command.includes(commandPath)) ||
			MANAGED_COMMAND_PATH_SUFFIXES.some((commandPath) => value.shell_command.includes(commandPath))
		)
	) {
		return true;
	}
	return Object.values(value).some((item) => valueContainsManagedScriptCommand(item));
}

function materializeManagedScriptPath(value, runtime) {
	if (Array.isArray(value)) {
		return value.map((item) => materializeManagedScriptPath(item, runtime));
	}
	if (!value || typeof value !== 'object') {
		return value;
	}
	return Object.fromEntries(
		Object.entries(value).map(([key, item]) => {
			if (key === 'shell_command' && typeof item === 'string') {
				return [
					key,
					item
						.replaceAll(LEGACY_MANAGED_SCRIPT_COMMAND_PATH, runtime.scriptTargetPath)
						.replaceAll(MANAGED_RECORDER_COMMAND_PATH, runtime.recorderLauncherTargetPath)
						.replaceAll(MANAGED_SPEEK_COMMAND_PATH, runtime.speekCommandTargetPath),
				];
			}
			return [key, materializeManagedScriptPath(item, runtime)];
		}),
	);
}

function matchManagedRule(rule, templateRule) {
	return (
		rule?.description === templateRule.description ||
		LEGACY_MANAGED_RULE_DESCRIPTIONS.has(rule?.description) ||
		valueContainsManagedScriptCommand(rule)
	);
}

function isDjiManipulator(manipulator) {
	return manipulator?.from?.consumer_key_code === 'volume_increment';
}

function filterManipulatorsForTriggerMode(manipulators = [], triggerMode) {
	if (triggerMode === TRIGGER_MODE_KEYBOARD) {
		return manipulators.filter((manipulator) => !isDjiManipulator(manipulator));
	}
	return manipulators;
}

export async function loadRuleTemplate(runtime, triggerMode = TRIGGER_MODE_KEYBOARD_DJI) {
	const template = JSON.parse(await fs.readFile(runtime.karabinerTemplatePath, 'utf-8'));
	const rule = structuredClone(template.rules[0]);
	rule.manipulators = filterManipulatorsForTriggerMode(rule.manipulators, triggerMode);
	return materializeManagedScriptPath(rule, runtime);
}

export async function loadKarabinerConfig(runtime) {
	return JSON.parse(await fs.readFile(runtime.karabinerConfigPath, 'utf-8'));
}

export async function writeKarabinerConfig(runtime, config) {
	await fs.mkdir(runtime.karabinerDir, { recursive: true });
	let mode = 0o600;
	try {
		mode = (await fs.stat(runtime.karabinerConfigPath)).mode & 0o777;
	} catch (error) {
		if (error.code !== 'ENOENT') throw error;
	}
	const temporaryPath = path.join(
		runtime.karabinerDir,
		`.${path.basename(runtime.karabinerConfigPath)}.${process.pid}.${randomUUID()}.tmp`,
	);
	try {
		await fs.writeFile(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, {
			encoding: 'utf-8',
			flag: 'wx',
			mode,
		});
		await fs.rename(temporaryPath, runtime.karabinerConfigPath);
		await fs.chmod(runtime.karabinerConfigPath, mode);
	} finally {
		await fs.rm(temporaryPath, { force: true });
	}
}

export function listProfiles(config) {
	return (config?.profiles || []).map((profile) => ({
		name: profile.name,
		selected: Boolean(profile.selected),
	}));
}

export function findProfile(config, requestedProfileName) {
	const profiles = config?.profiles || [];
	if (profiles.length === 0) {
		throw new Error('No Karabiner profiles found.');
	}
	if (requestedProfileName) {
		const matched = profiles.find((profile) => profile.name === requestedProfileName);
		if (!matched) {
			throw new Error(`Karabiner profile not found: ${requestedProfileName}`);
		}
		return matched;
	}
	return profiles.find((profile) => profile.selected) || profiles[0];
}

export function setSelectedProfile(config, requestedProfileName) {
	const profile = findProfile(config, requestedProfileName);
	for (const currentProfile of config?.profiles || []) {
		currentProfile.selected = currentProfile.name === profile.name;
	}
	return profile;
}

export function cloneProfile(config, sourceProfileName, newProfileName) {
	const sourceProfile = findProfile(config, sourceProfileName);
	if (!newProfileName?.trim()) {
		throw new Error('New Karabiner profile name is required.');
	}
	if ((config?.profiles || []).some((profile) => profile.name === newProfileName)) {
		throw new Error(`Karabiner profile already exists: ${newProfileName}`);
	}
	const clonedProfile = structuredClone(sourceProfile);
	clonedProfile.name = newProfileName;
	clonedProfile.selected = false;
	config.profiles.push(clonedProfile);
	return clonedProfile;
}

export function resolveTargetProfile(config, profileOptions = {}) {
	const profileStrategy = profileOptions.profileStrategy || 'active';

	switch (profileStrategy) {
		case 'active': {
			const activeProfile = setSelectedProfile(config, findProfile(config).name);
			return {
				profileName: activeProfile.name,
				profileStrategy,
				sourceProfileName: null,
			};
		}
		case 'existing': {
			if (!profileOptions.profileName) {
				throw new Error('A Karabiner profile name is required for the existing profile strategy.');
			}
			const targetProfile = setSelectedProfile(config, profileOptions.profileName);
			return {
				profileName: targetProfile.name,
				profileStrategy,
				sourceProfileName: null,
			};
		}
		case 'clone': {
			const sourceProfileName = profileOptions.sourceProfileName || findProfile(config).name;
			if (!profileOptions.newProfileName) {
				throw new Error('A new Karabiner profile name is required for the clone strategy.');
			}
			cloneProfile(config, sourceProfileName, profileOptions.newProfileName);
			const targetProfile = setSelectedProfile(config, profileOptions.newProfileName);
			return {
				profileName: targetProfile.name,
				profileStrategy,
				sourceProfileName,
			};
		}
		default:
			throw new Error(`Unsupported Karabiner profile strategy: ${profileStrategy}`);
	}
}

export function inferTriggerMode(manifest, managedProfiles = []) {
	if (manifest?.triggerMode === TRIGGER_MODE_KEYBOARD || manifest?.triggerMode === TRIGGER_MODE_KEYBOARD_DJI) {
		return manifest.triggerMode;
	}
	return managedProfiles.some((profile) => profile.hasDevice) ? TRIGGER_MODE_KEYBOARD_DJI : TRIGGER_MODE_KEYBOARD;
}

export function syncManagedEntries(config, templateRule, requestedProfileName, { includeManagedDevice = true } = {}) {
	removeManagedEntries(config, templateRule);
	const profile = ensureProfileArrays(findProfile(config, requestedProfileName));
	const existingRules = profile.complex_modifications.rules.filter(
		(rule) => !matchManagedRule(rule, templateRule),
	);
	profile.complex_modifications.rules = [...existingRules, templateRule];

	if (includeManagedDevice) {
		const existingDevices = profile.devices.filter((device) => !matchManagedDevice(device));
		profile.devices = [...existingDevices, ...MANAGED_DEVICES.map((device) => structuredClone(device))];
	}

	return { profileName: profile.name };
}

export function removeManagedEntries(config, templateRule) {
	let removedRuleCount = 0;
	let removedDeviceCount = 0;

	for (const profile of config?.profiles || []) {
		ensureProfileArrays(profile);
		const originalRuleCount = profile.complex_modifications.rules.length;
		const originalDeviceCount = profile.devices.length;

		profile.complex_modifications.rules = profile.complex_modifications.rules.filter(
			(rule) => !matchManagedRule(rule, templateRule),
		);
		profile.devices = profile.devices.filter((device) => !matchManagedDevice(device));

		removedRuleCount += originalRuleCount - profile.complex_modifications.rules.length;
		removedDeviceCount += originalDeviceCount - profile.devices.length;
	}

	return { removedRuleCount, removedDeviceCount };
}

export function findManagedEntries(config, templateRule) {
	const profiles = [];
	for (const profile of config?.profiles || []) {
		const rules = profile?.complex_modifications?.rules || [];
		const devices = profile?.devices || [];
		const hasRule = rules.some((rule) => matchManagedRule(rule, templateRule));
		const hasDevice = devices.some((device) => matchManagedDevice(device));
		if (hasRule || hasDevice) {
			profiles.push({
				name: profile.name,
				hasRule,
				hasDevice,
				selected: Boolean(profile.selected),
			});
		}
	}
	return profiles;
}

export function isManagedRuleCurrent(profile, templateRule) {
	const rules = profile?.complex_modifications?.rules || [];
	const managedRules = rules.filter((rule) => matchManagedRule(rule, templateRule));
	return managedRules.length === 1 && stableStringify(managedRules[0]) === stableStringify(templateRule);
}
