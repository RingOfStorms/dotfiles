Note that in zitadel there are several settings that many of the apps need. Specifically the flat roles complement on tokens

flatRolesClaim , timeout in seconds = 10
flowType: complement_token
-> pre user info creation
-> pre access token creation

```js
/**
 * Adds an additional claim in the token with roles in flat format.
 * 
 * The role claims of the token look like the following:
 * 
 * // added by the code below
 * "flatRolesClaim": ["test", "role2", ...],
 * // added automatically
 * "urn:zitadel:iam:org:project:roles": {
 *   "test": {
 *     "201982826478953724": "zitadel.localhost"
 *   }
 * }
 *
 * Flow: Complement token, Triggers: Pre Userinfo creation, Pre access token creation
 *
 * @param ctx
 * @param api
 */

function flatRolesClaim(ctx, api) {
  if (ctx.v1.user.grants == undefined || ctx.v1.user.grants.count == 0) {
    return;
  }

  let grants = [];
  ctx.v1.user.grants.grants.forEach(claim => {
    claim.roles.forEach(role => {
        grants.push(role);  
    })
  })
  
  api.v1.claims.setClaim('flatRolesClaim', grants);
}
```
