#!/usr/bin/env bash

function _kv() {
	local key="${1}"
	shift
	for arg in "${@}"; do
		if [[ "${arg}" == "${key}="* ]]; then
			echo "${key}=${arg#*=}"
			return 0
		fi
	done
	return 1
}
function _v() {
	local key="${1}"
	shift
	for arg in "${@}"; do
		if [[ "${arg}" == "${key}="* ]]; then
			echo "${arg#*=}"
			return 0
		fi
	done
	return 1
}
COMMAND="${1}"
shift
if [[ -z "${COMMAND}" || "${COMMAND}" = "help" ]]; then
	cat <<'USAGE'
Usage:
?                      : List available modules
all                    : Build all modules
[module]// || [module] : Build [module]
[module]//?            : List targets in [module]
[module]//[target]?    : Show target implementation
help                   : Print this message
USAGE
elif [[ "${COMMAND}" = "?" ]]; then
	find . -type f -maxdepth 5 -name Makefile.sh 2>/dev/null -exec dirname {} \; | sed -E 's|^\./||; s|^\.$|//|'
elif [[ "${COMMAND}" = "all" ]]; then
	find . -type f -maxdepth 5 -name Makefile.sh 2>/dev/null -exec dirname {} \; | while IFS= read MODULE; do
		cd "${MODULE}"; . Makefile.sh > /dev/null 2>&1

			init "${@}" < /dev/tty || break
		
cd - 2>&1 > /dev/null
	done
else
	if [[ "${COMMAND}" == *"//"* ]]; then
		MODULE="${COMMAND%%//*}"
		TARGET="${COMMAND#*//}"
	else
		MODULE="${COMMAND}"
	fi
	MODULE="${MODULE:-.}"
	TARGET="${TARGET:-init}"
	if [ -f "${MODULE}/Makefile.sh" ]; then
		cd "${MODULE}"; . Makefile.sh > /dev/null 2>&1

			if [ "${TARGET}" = "?" ]; then
				declare -F | cut -d' ' -f3 | grep -vE "^_"
			elif [[ "${TARGET}" == *\? ]]; then
				type "${TARGET%?}" | grep -vE "^${TARGET} is a function$"
			else
				if declare -F | cut -d' ' -f3 | grep -vE "^_" | grep -q "${TARGET}"; then
					"${TARGET}" "${@}"
				else
					echo "Error: Target not implemented: ${MODULE}//${TARGET}" >&2
				fi
			fi
		
cd - 2>&1 > /dev/null
	else
		echo -e "Error: Module not found: ${MODULE}
" >&2
		cat <<'USAGE'
Usage:
?                      : List available modules
all                    : Build all modules
[module]// || [module] : Build [module]
[module]//?            : List targets in [module]
[module]//[target]?    : Show target implementation
help                   : Print this message
USAGE
	fi
fi

