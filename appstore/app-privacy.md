# App Privacy questionnaire (App Store Connect → App Privacy)

**Do you or your third-party partners collect data from this app?** → **No, we do not collect data from this app.**

Justification: all processing happens on device. There are no servers, analytics, or third-party SDKs. Location is
written only into image files on the user's device. Under Apple's definition that is not "collection",
because it is not transmitted off the device by the developer.

Result shown on the App Store: **Data Not Collected**.

Privacy manifest: `App/PrivacyInfo.xcprivacy` declares no tracking and no collected data, plus the required-reason
APIs used: UserDefaults (CA92.1) and file timestamps (C617.1).
