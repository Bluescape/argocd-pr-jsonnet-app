
export PR_REF=refs/heads/master/ss

if [[ ${PR_REF} =~ ^refs/tags/*.*.*$ ]]; then
echo "tag"
elif [[ ${PR_REF} =~ ^refs/heads/(master|develop|release|main)$ ]]; then
echo "br"
else
echo "no ${PR_REF}" 
fi