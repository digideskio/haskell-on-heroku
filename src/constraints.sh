#!/usr/bin/env bash


function echo_constraints_tmp_config () {
	mktemp -u "/tmp/halcyon-constraints.cabal.config.XXXXXXXXXX"
}




function echo_constraints_digest () {
	openssl sha1 | sed 's/^.* //'
}


function echo_constraints () {
	awk 'BEGIN { printf "constraints:"; separator = " " }
		!/^$/ { printf "%s%s ==%s", separator, $1, $2; separator = ",\n             " }
		END { printf "\n" }'
}


function echo_constraints_difference () {
	expect_args old_constraints new_constraints -- "$@"

	local old_digest new_digest
	old_digest=$( echo_constraints_digest <<<"${old_constraints}" ) || die
	new_digest=$( echo_constraints_digest <<<"${new_constraints}" ) || die

	local tmp_old_config tmp_new_config
	tmp_old_config=$( echo_constraints_tmp_config ) || die
	tmp_new_config=$( echo_constraints_tmp_config ) || die

	echo_constraints <<<"${old_constraints}" >"${tmp_old_config}" || die
	echo_constraints <<<"${new_constraints}" >"${tmp_new_config}" || die

	echo "--- ${old_digest:0:7}/cabal.config"
	echo "+++ ${new_digest:0:7}/cabal.config"
	diff -u "${tmp_old_config}" "${tmp_new_config}" | tail -n +3 || true

	rm -f "${tmp_old_config}" "${tmp_new_config}" || die
}




function read_constraints () {
	awk '/^ *[Cc]onstraints:/, !/[:,]/ { print }' |
		sed 's/[Cc]onstraints://;s/[, ]//g;s/==/ /;/^$/d'
}




function filter_valid_constraints () {
	local -A constraints_A

	local candidate_package candidate_version
	while read -r candidate_package candidate_version; do
		if [ -n "${constraints_A[${candidate_package}]:+_}" ]; then
			die "Expected at most one ${candidate_package} constraint"
		fi
		constraints_A["${candidate_package}"]="${candidate_version}"

		echo "${candidate_package} ${candidate_version}"
	done

	if [ -z "${constraints_A[base]:+_}" ]; then
		die 'Expected base constraint'
	fi
}


function score_constraints () {
	local constraints sandbox_tag
	expect_args constraints sandbox_tag -- "$@"

	local sandbox_description
	sandbox_description=$( echo_sandbox_description "${sandbox_tag}" ) || die

	local -A constraints_A

	local package version
	while read -r package version; do
		constraints_A["${package}"]="${version}"
	done <<<"${constraints}"

	local score candidate_package candidate_version
	score=0
	while read -r candidate_package candidate_version; do
		local version
		version="${constraints_A[${candidate_package}]:-}"
		if [ -z "${version}" ]; then
			log_indent "Ignoring ${sandbox_description} as ${candidate_package} is not needed"
			echo 0
			return 0
		fi
		if [ "${candidate_version}" != "${version}" ]; then
			log_indent "Ignoring ${sandbox_description} as ${candidate_package}-${version} is needed and not ${candidate_version}"
			echo 0
			return 0
		fi
		score=$(( ${score} + 1 ))
	done

	log_indent "${score}"$'\t'"${sandbox_description}"
	echo "${score}"
}




function detect_app_constraint () {
	local build_dir
	expect_args build_dir -- "$@"

	local app_name app_version
	app_name=$( detect_app_name "${build_dir}" ) || die
	app_version=$( detect_app_version "${build_dir}" ) || die

	echo "${app_name} ${app_version}"
}


function detect_constraints () {
	local build_dir
	expect_args build_dir -- "$@"
	expect "${build_dir}/cabal.config"

	# NOTE: An application should not be its own dependency.
	# https://github.com/haskell/cabal/issues/1908

	local app_constraint
	app_constraint=$( detect_app_constraint "${build_dir}" ) || die

	read_constraints <"${build_dir}/cabal.config" |
		sort_naturally |
		filter_valid_constraints |
		filter_not_matching "^${app_constraint}$" || die
}




function freeze_constraints () {
	local build_dir implicit
	expect_args build_dir implicit -- "$@"
	expect "${build_dir}"

	# NOTE: Cabal freeze should be able to output to stdout.
	# https://github.com/haskell/cabal/issues/1916

	local saved_config
	saved_config=''
	if [ -f "${build_dir}/cabal.config" ]; then
		saved_config=$( echo_constraints_tmp_config ) || die
		mv "${build_dir}/cabal.config" "${saved_config}" || die
	fi

	if (( ${implicit} )); then
		silently cabal_do "${build_dir}" --no-require-sandbox freeze || die
	else
		silently sandboxed_cabal_do "${build_dir}" freeze || die
	fi

	local sandbox_constraints
	sandbox_constraints=$( detect_constraints "${build_dir}" ) || die

	rm -f "${build_dir}/cabal.config" || die
	if [ -n "${saved_config}" ]; then
		mv "${saved_config}" "${build_dir}/cabal.config" || die
	fi

	echo "${sandbox_constraints}"
}
