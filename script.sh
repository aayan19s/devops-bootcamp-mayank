#!/bin/bash

echo "======================================================"
echo "         Welcome to Repo Utilities / Manager          "
echo "======================================================"
>template_repo.txt
>repo_list.txt
>rulesets.json
gh auth status > .gitstatus

if grep -q "Logged in to github.com account" .gitstatus; then
    git_user=$(gh auth status | grep Logged | cut -d" " -f9)
    echo "Logged in user is $git_user."
    template_repos=$(gh repo list $git_user --limit 1000 --json name,isTemplate --jq '.[] | select(.isTemplate == true) | .name')
    echo $template_repos | tr ' ' '\n' > template_repo.txt
    repo_list=$(gh repo list $git_user --limit 1000 --json name --jq '.[].name')
    echo "Following are the repositories already created: "
    echo "======================================================"
    echo "$repo_list "
    echo "======================================================"
    echo $repo_list | tr ' ' '\n' > repo_list.txt
    echo
    echo "Available repositories with templates enabled are: "
    echo "======================================================"
    echo "$template_repos"
    echo "======================================================"
    echo "Now, we are going to create a new repository using one of the above templates repositories."
    echo "Please enter the new repository name: "
    echo "( Please make sure to give a unique repository name from the above listed ones)"
    read repo_name
    if [ -z "$repo_name" ]; then
        echo "Repository name cannot be empty. Exiting."
        exit 1
    fi
    echo "Repository name entered is: "
    echo $repo_name
    if grep -Fxq $repo_name repo_list.txt; then
        echo "The repository already exists. Please try again."
        exit
    fi
    echo "Please enter the template from the above list:"
    read template_name
    if [ -z "$template_name" ]; then
        echo "Template name cannot be empty. Exiting."
        exit 1
    fi
    echo "Selected repository with the template is:"
    echo $template_name
    if ! grep -Fxq $template_name template_repo.txt; then
        echo "Correct template not selected. Try again."
        exit
    fi

    rulesets=$(gh api repos/$git_user/$template_name/rulesets --jq '.[].id' | while read -r id; do gh api repos/$git_user/$template_name/rulesets/$id; done | jq -s 'map({name,enforcement,target,conditions,rules,bypass_actors} | with_entries(select(.value != null)))')
    echo "$rulesets" > rulesets.json

    echo "Creating a new repository $repo_name using template repository $template_name: "
    gh repo create $git_user/$repo_name --template $template_name --public
    echo "Repository $repo_name created."

    jq -c '.[]' rulesets.json > split_rulesets.txt
    while IFS= read -r ruleset; do
        echo "$ruleset" | gh api -X POST repos/$git_user/$repo_name/rulesets --input - > /dev/null
    done < split_rulesets.txt
    echo "Copied rulesets from $template_name to new repo $repo_name"

    branches=$(gh api repos/$git_user/$template_name/branches --jq '.[].name')

    while IFS= read -r branch; do
        protection_json=$(gh api repos/$git_user/$template_name/branches/$branch/protection 2>/dev/null || echo "")
        if [ -n "$protection_json" ]; then
            filtered_protection=$(echo "$protection_json" | jq '
              def fix_enabled:
                if type == "object" and has("enabled") and ((keys | length) == 1 or (keys | length) == 2 and has("url")) then
                  .enabled
                elif type == "object" then
                  with_entries(.value |= fix_enabled)
                elif type == "array" then
                  map(fix_enabled)
                else
                  .
                end;

              fix_enabled |
              del(.url, .created_at, .updated_at, .resource_name, ."_links") |

              .required_status_checks |= ( if . == {} or . == null then null else
                .strict //= false | .contexts //= []
              end ) |
              .restrictions |= ( if . == {} or . == null then null else . end )
            ')

            echo "$filtered_protection" | gh api -X PUT repos/$git_user/$repo_name/branches/$branch/protection --input - > /dev/null
            if [ $? -eq 0 ]; then
                echo "Branch protection applied successfully for $branch."
            else
                echo "Warning: Could not apply branch protection for $branch (branch may not exist in new repo yet)."
            fi
        else
            echo "No branch protection set for $branch, skipping."
        fi
    done <<< "$branches"

else
    echo "You are not authenticated with github yet. Let's get you authenticated and then you can run the script again to create repositories."
    gh auth login
fi
