/// <reference path="../pb_data/types.d.ts" />
// Adds per-contact `precision` (and keeps the full schema in sync). Re-imports
// the current collections; safe/idempotent on both fresh and existing DBs.
migrate((app) => {
  const toImport = [
    {
        "id":  "_pb_users_auth_",
        "listRule":  "id = @request.auth.id",
        "viewRule":  "id = @request.auth.id",
        "createRule":  "",
        "updateRule":  "id = @request.auth.id",
        "deleteRule":  "@request.auth.id = id",
        "name":  "users",
        "type":  "auth",
        "fields":  [
                       {
                           "autogeneratePattern":  "[a-z0-9]{15}",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text3208210256",
                           "max":  15,
                           "min":  15,
                           "name":  "id",
                           "pattern":  "^[a-z0-9]+$",
                           "presentable":  false,
                           "primaryKey":  true,
                           "required":  true,
                           "system":  true,
                           "type":  "text"
                       },
                       {
                           "cost":  0,
                           "help":  "",
                           "hidden":  true,
                           "id":  "password901924565",
                           "max":  0,
                           "min":  8,
                           "name":  "password",
                           "pattern":  "",
                           "presentable":  false,
                           "required":  true,
                           "system":  true,
                           "type":  "password"
                       },
                       {
                           "autogeneratePattern":  "[a-zA-Z0-9]{50}",
                           "help":  "",
                           "hidden":  true,
                           "id":  "text2504183744",
                           "max":  60,
                           "min":  30,
                           "name":  "tokenKey",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  true,
                           "system":  true,
                           "type":  "text"
                       },
                       {
                           "exceptDomains":  [

                                             ],
                           "help":  "",
                           "hidden":  false,
                           "id":  "email3885137012",
                           "name":  "email",
                           "onlyDomains":  [

                                           ],
                           "presentable":  false,
                           "required":  true,
                           "system":  true,
                           "type":  "email"
                       },
                       {
                           "help":  "",
                           "hidden":  false,
                           "id":  "bool1547992806",
                           "name":  "emailVisibility",
                           "presentable":  false,
                           "required":  false,
                           "system":  true,
                           "type":  "bool"
                       },
                       {
                           "help":  "",
                           "hidden":  false,
                           "id":  "bool256245529",
                           "name":  "verified",
                           "presentable":  false,
                           "required":  false,
                           "system":  true,
                           "type":  "bool"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text1579384326",
                           "max":  255,
                           "min":  0,
                           "name":  "name",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  false,
                           "system":  false,
                           "type":  "text"
                       },
                       {
                           "help":  "",
                           "hidden":  false,
                           "id":  "file376926767",
                           "maxSelect":  1,
                           "maxSize":  0,
                           "mimeTypes":  [
                                             "image/jpeg",
                                             "image/png",
                                             "image/svg+xml",
                                             "image/gif",
                                             "image/webp"
                                         ],
                           "name":  "avatar",
                           "presentable":  false,
                           "protected":  false,
                           "required":  false,
                           "system":  false,
                           "thumbs":  [

                                      ],
                           "type":  "file"
                       },
                       {
                           "hidden":  false,
                           "id":  "autodate2990389176",
                           "name":  "created",
                           "onCreate":  true,
                           "onUpdate":  false,
                           "presentable":  false,
                           "system":  false,
                           "type":  "autodate"
                       },
                       {
                           "hidden":  false,
                           "id":  "autodate3332085495",
                           "name":  "updated",
                           "onCreate":  true,
                           "onUpdate":  true,
                           "presentable":  false,
                           "system":  false,
                           "type":  "autodate"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text1727648867",
                           "max":  20000,
                           "min":  0,
                           "name":  "public_key",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  false,
                           "system":  false,
                           "type":  "text"
                       },
                       {
                           "help":  "",
                           "hidden":  false,
                           "id":  "date846843460",
                           "max":  "",
                           "min":  "",
                           "name":  "last_seen",
                           "presentable":  false,
                           "required":  false,
                           "system":  false,
                           "type":  "date"
                       }
                   ],
        "indexes":  [
                        "CREATE UNIQUE INDEX `idx_tokenKey__pb_users_auth_` ON `users` (`tokenKey`)",
                        "CREATE UNIQUE INDEX `idx_email__pb_users_auth_` ON `users` (`email`) WHERE `email` != \u0027\u0027"
                    ],
        "created":  "2026-09-01 20:47:05.740Z",
        "updated":  "2026-09-13 17:40:04.366Z",
        "system":  false,
        "authRule":  "",
        "manageRule":  null,
        "authAlert":  {
                          "enabled":  true,
                          "emailTemplate":  {
                                                "subject":  "Login from a new location",
                                                "body":  "\u003cp\u003eHello,\u003c/p\u003e\n\u003cp\u003eWe noticed a login to your {APP_NAME} account from a new location:\u003c/p\u003e\n\u003cp\u003e\u003cem\u003e{ALERT_INFO}\u003c/em\u003e\u003c/p\u003e\n\u003cp\u003e\u003cstrong\u003eIf this wasn\u0027t you, you should immediately change your {APP_NAME} account password to revoke access from all other locations.\u003c/strong\u003e\u003c/p\u003e\n\u003cp\u003eIf this was you, you may disregard this email.\u003c/p\u003e\n\u003cp\u003e\n  Thanks,\u003cbr/\u003e\n  {APP_NAME} team\n\u003c/p\u003e"
                                            }
                      },
        "oauth2":  {
                       "providers":  [

                                     ],
                       "mappedFields":  {
                                            "id":  "",
                                            "name":  "name",
                                            "username":  "",
                                            "avatarURL":  "avatar"
                                        },
                       "enabled":  false
                   },
        "passwordAuth":  {
                             "enabled":  true,
                             "identityFields":  [
                                                    "email"
                                                ]
                         },
        "mfa":  {
                    "enabled":  false,
                    "duration":  600,
                    "rule":  ""
                },
        "otp":  {
                    "enabled":  false,
                    "duration":  180,
                    "length":  8,
                    "emailTemplate":  {
                                          "subject":  "OTP for {APP_NAME}",
                                          "body":  "\u003cp\u003eHello,\u003c/p\u003e\n\u003cp\u003eYour one-time password is: \u003cstrong\u003e{OTP}\u003c/strong\u003e\u003c/p\u003e\n\u003cp\u003e\u003ci\u003eIf you didn\u0027t ask for the one-time password, you can ignore this email.\u003c/i\u003e\u003c/p\u003e\n\u003cp\u003e\n  Thanks,\u003cbr/\u003e\n  {APP_NAME} team\n\u003c/p\u003e"
                                      }
                },
        "authToken":  {
                          "duration":  432000
                      },
        "passwordResetToken":  {
                                   "duration":  1800
                               },
        "emailChangeToken":  {
                                 "duration":  1800
                             },
        "verificationToken":  {
                                  "duration":  86400
                              },
        "fileToken":  {
                          "duration":  180
                      },
        "verificationTemplate":  {
                                     "subject":  "Verify your {APP_NAME} email",
                                     "body":  "\u003cp\u003eHello,\u003c/p\u003e\n\u003cp\u003eThank you for joining us at {APP_NAME}.\u003c/p\u003e\n\u003cp\u003eClick on the button below to verify your email address.\u003c/p\u003e\n\u003cp\u003e\n  \u003ca class=\"btn\" href=\"{APP_URL}/_/#/auth/confirm-verification/{TOKEN}\" target=\"_blank\" rel=\"noopener\"\u003eVerify\u003c/a\u003e\n\u003c/p\u003e\n\u003cp\u003e\u003ci\u003eIf you didn\u0027t recently register, please ignore this email.\u003c/i\u003e\u003c/p\u003e\n\u003cp\u003e\n  Thanks,\u003cbr/\u003e\n  {APP_NAME} team\n\u003c/p\u003e"
                                 },
        "resetPasswordTemplate":  {
                                      "subject":  "Reset your {APP_NAME} password",
                                      "body":  "\u003cp\u003eHello,\u003c/p\u003e\n\u003cp\u003eClick on the button below to reset your password.\u003c/p\u003e\n\u003cp\u003e\n  \u003ca class=\"btn\" href=\"{APP_URL}/_/#/auth/confirm-password-reset/{TOKEN}\" target=\"_blank\" rel=\"noopener\"\u003eReset password\u003c/a\u003e\n\u003c/p\u003e\n\u003cp\u003e\u003ci\u003eIf you didn\u0027t ask to reset your password, please ignore this email.\u003c/i\u003e\u003c/p\u003e\n\u003cp\u003e\n  Thanks,\u003cbr/\u003e\n  {APP_NAME} team\n\u003c/p\u003e"
                                  },
        "confirmEmailChangeTemplate":  {
                                           "subject":  "Confirm your {APP_NAME} new email address",
                                           "body":  "\u003cp\u003eHello,\u003c/p\u003e\n\u003cp\u003eClick on the button below to confirm your new email address.\u003c/p\u003e\n\u003cp\u003e\n  \u003ca class=\"btn\" href=\"{APP_URL}/_/#/auth/confirm-email-change/{TOKEN}\" target=\"_blank\" rel=\"noopener\"\u003eConfirm new email\u003c/a\u003e\n\u003c/p\u003e\n\u003cp\u003e\u003ci\u003eIf you didn\u0027t ask to change your email address, please ignore this email.\u003c/i\u003e\u003c/p\u003e\n\u003cp\u003e\n  Thanks,\u003cbr/\u003e\n  {APP_NAME} team\n\u003c/p\u003e"
                                       }
    },
    {
        "id":  "pbc_1930317162",
        "listRule":  "@request.auth.id = owner.id || @request.auth.id = peer.id",
        "viewRule":  "@request.auth.id = owner.id || @request.auth.id = peer.id",
        "createRule":  "@request.auth.id = owner.id",
        "updateRule":  "@request.auth.id = owner.id",
        "deleteRule":  "@request.auth.id = owner.id",
        "name":  "contacts",
        "type":  "base",
        "fields":  [
                       {
                           "autogeneratePattern":  "[a-z0-9]{15}",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text3208210256",
                           "max":  15,
                           "min":  15,
                           "name":  "id",
                           "pattern":  "^[a-z0-9]+$",
                           "presentable":  false,
                           "primaryKey":  true,
                           "required":  true,
                           "system":  true,
                           "type":  "text"
                       },
                       {
                           "cascadeDelete":  true,
                           "collectionId":  "_pb_users_auth_",
                           "help":  "",
                           "hidden":  false,
                           "id":  "relation3479234172",
                           "maxSelect":  1,
                           "minSelect":  0,
                           "name":  "owner",
                           "presentable":  false,
                           "required":  true,
                           "system":  false,
                           "type":  "relation"
                       },
                       {
                           "cascadeDelete":  true,
                           "collectionId":  "_pb_users_auth_",
                           "help":  "",
                           "hidden":  false,
                           "id":  "relation2733046201",
                           "maxSelect":  1,
                           "minSelect":  0,
                           "name":  "peer",
                           "presentable":  false,
                           "required":  true,
                           "system":  false,
                           "type":  "relation"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text2063623452",
                           "max":  50,
                           "min":  0,
                           "name":  "status",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  false,
                           "system":  false,
                           "type":  "text"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text3571535660",
                           "max":  200,
                           "min":  0,
                           "name":  "peer_name",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  false,
                           "system":  false,
                           "type":  "text"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text1369032766",
                           "max":  20000,
                           "min":  0,
                           "name":  "peer_pubkey",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  false,
                           "system":  false,
                           "type":  "text"
                       },
                       {
                           "hidden":  false,
                           "id":  "autodate2990389176",
                           "name":  "created",
                           "onCreate":  true,
                           "onUpdate":  false,
                           "presentable":  false,
                           "system":  false,
                           "type":  "autodate"
                       },
                       {
                           "hidden":  false,
                           "id":  "autodate3332085495",
                           "name":  "updated",
                           "onCreate":  true,
                           "onUpdate":  true,
                           "presentable":  false,
                           "system":  false,
                           "type":  "autodate"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text1307610870",
                           "max":  20,
                           "min":  0,
                           "name":  "precision",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  false,
                           "system":  false,
                           "type":  "text"
                       }
                   ],
        "indexes":  [

                    ],
        "created":  "2026-09-01 20:48:28.311Z",
        "updated":  "2026-09-14 01:12:21.497Z",
        "system":  false
    },
    {
        "id":  "pbc_3043038444",
        "listRule":  "@request.auth.id = recipient.id || @request.auth.id = sender.id",
        "viewRule":  "@request.auth.id = recipient.id || @request.auth.id = sender.id",
        "createRule":  "@request.auth.id = sender.id",
        "updateRule":  "@request.auth.id = sender.id",
        "deleteRule":  "@request.auth.id = sender.id",
        "name":  "location_shares",
        "type":  "base",
        "fields":  [
                       {
                           "autogeneratePattern":  "[a-z0-9]{15}",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text3208210256",
                           "max":  15,
                           "min":  15,
                           "name":  "id",
                           "pattern":  "^[a-z0-9]+$",
                           "presentable":  false,
                           "primaryKey":  true,
                           "required":  true,
                           "system":  true,
                           "type":  "text"
                       },
                       {
                           "cascadeDelete":  true,
                           "collectionId":  "_pb_users_auth_",
                           "help":  "",
                           "hidden":  false,
                           "id":  "relation1593854671",
                           "maxSelect":  1,
                           "minSelect":  0,
                           "name":  "sender",
                           "presentable":  false,
                           "required":  true,
                           "system":  false,
                           "type":  "relation"
                       },
                       {
                           "cascadeDelete":  true,
                           "collectionId":  "_pb_users_auth_",
                           "help":  "",
                           "hidden":  false,
                           "id":  "relation1745156937",
                           "maxSelect":  1,
                           "minSelect":  0,
                           "name":  "recipient",
                           "presentable":  false,
                           "required":  true,
                           "system":  false,
                           "type":  "relation"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text4235667061",
                           "max":  100000,
                           "min":  0,
                           "name":  "ciphertext",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  true,
                           "system":  false,
                           "type":  "text"
                       },
                       {
                           "hidden":  false,
                           "id":  "autodate2990389176",
                           "name":  "created",
                           "onCreate":  true,
                           "onUpdate":  false,
                           "presentable":  false,
                           "system":  false,
                           "type":  "autodate"
                       },
                       {
                           "hidden":  false,
                           "id":  "autodate3332085495",
                           "name":  "updated",
                           "onCreate":  true,
                           "onUpdate":  true,
                           "presentable":  false,
                           "system":  false,
                           "type":  "autodate"
                       }
                   ],
        "indexes":  [

                    ],
        "created":  "2026-09-01 20:48:28.317Z",
        "updated":  "2026-09-13 16:15:38.375Z",
        "system":  false
    },
    {
        "id":  "pbc_2234146199",
        "listRule":  "@request.auth.id = target.id",
        "viewRule":  "@request.auth.id = target.id",
        "createRule":  "@request.auth.id = from.id",
        "updateRule":  null,
        "deleteRule":  "@request.auth.id = target.id",
        "name":  "pair_requests",
        "type":  "base",
        "fields":  [
                       {
                           "autogeneratePattern":  "[a-z0-9]{15}",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text3208210256",
                           "max":  15,
                           "min":  15,
                           "name":  "id",
                           "pattern":  "^[a-z0-9]+$",
                           "presentable":  false,
                           "primaryKey":  true,
                           "required":  true,
                           "system":  true,
                           "type":  "text"
                       },
                       {
                           "cascadeDelete":  true,
                           "collectionId":  "_pb_users_auth_",
                           "help":  "",
                           "hidden":  false,
                           "id":  "relation1181691900",
                           "maxSelect":  1,
                           "minSelect":  0,
                           "name":  "target",
                           "presentable":  false,
                           "required":  true,
                           "system":  false,
                           "type":  "relation"
                       },
                       {
                           "cascadeDelete":  true,
                           "collectionId":  "_pb_users_auth_",
                           "help":  "",
                           "hidden":  false,
                           "id":  "relation3105530224",
                           "maxSelect":  1,
                           "minSelect":  0,
                           "name":  "from",
                           "presentable":  false,
                           "required":  true,
                           "system":  false,
                           "type":  "relation"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text733324261",
                           "max":  200,
                           "min":  0,
                           "name":  "from_name",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  false,
                           "system":  false,
                           "type":  "text"
                       },
                       {
                           "autogeneratePattern":  "",
                           "help":  "",
                           "hidden":  false,
                           "id":  "text3793614142",
                           "max":  20000,
                           "min":  0,
                           "name":  "from_pubkey",
                           "pattern":  "",
                           "presentable":  false,
                           "primaryKey":  false,
                           "required":  true,
                           "system":  false,
                           "type":  "text"
                       },
                       {
                           "hidden":  false,
                           "id":  "autodate2990389176",
                           "name":  "created",
                           "onCreate":  true,
                           "onUpdate":  false,
                           "presentable":  false,
                           "system":  false,
                           "type":  "autodate"
                       },
                       {
                           "hidden":  false,
                           "id":  "autodate3332085495",
                           "name":  "updated",
                           "onCreate":  true,
                           "onUpdate":  true,
                           "presentable":  false,
                           "system":  false,
                           "type":  "autodate"
                       }
                   ],
        "indexes":  [

                    ],
        "created":  "2026-09-01 23:52:24.954Z",
        "updated":  "2026-09-13 16:15:38.403Z",
        "system":  false
    }
];
  app.importCollections(toImport, false);
}, (app) => {});

