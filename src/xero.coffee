# Description:
#   Xero reimbursements
#
# Commands:
#   hubot xero help - Displays a short help message, can file reimbursements!
#
# Hidden:
#   hubot xero member add <slack name> [email, optional]- Allow a user to submit reimbursements
#   hubot xero member delete <slack name> - Removes user access to submit reimbursements
#
# Config:
#   HUBOT_XERO_CONTACT_ID
#   HUBOT_XERO_CONSUMER_KEY
#   HUBOT_XERO_CONSUMER_SECRET
#
# Author:
#   Detry322

fs = require 'fs'
request = require 'request'
Xero = require 'xero'
dateformat = require 'dateformat'
streamBuffers = require 'stream-buffers'

xero = try
  private_key = fs.readFileSync('xero/private_key.pem', 'ascii')
  new Xero(process.env.HUBOT_XERO_CONSUMER_KEY, process.env.HUBOT_ENV_CONSUMER_SECRET, private_key);
catch e
  null

# submitReceipt = (robot, res, receipt_id) ->
#   res.send "Step 3: Submitting receipt for reimbursement..."
#   res.send "Success! You should receive a check for $#{res.reimbursement_amount} in a couple of days. You can track progress on https://xero.com"


# createReceipt = (robot, res, description, amount, budget) ->
#   res.send "Step 1: Creating receipt in xero..."
#   uploadImage(robot, res, "blah")

# handleImageMessage = (robot, res) ->
#   if not res.message.user['xero-identifier']?
#     res.send "You haven't been added to xero just yet. Ask pkt-it"
#     return
#   comment_array = res.message?.rawMessage?.file?.initial_comment?.comment?.split('\n')
#   if comment_array?.length != 3
#     return badFormat(res)
#   description = comment_array[0]
#   amount = Number(comment_array[1].replace(/[^0-9\.]+/g,""))
#   budget = comment_array[2]
#   if isNaN(amount) or amount == 0
#     return badFormat(res)
#   res.reimbursement_amount = amount
#   createReceipt(robot, res, description, amount, budget)

# printBudgets = (robot, res) ->
#   budgets = robot.brain.get('xero-budgets') or {}
#   result = "We have the following budgets available. Please use the shorthand when referring to a budget.\n\n"
#   for own shorthand, budget of budgets
#     result += "*#{budget['shorthand']}*: #{budget['description']}\n"
#   if Object.keys(budgets).length == 0
#     result += "(No budgets)"
#   res.send result
#

  # robot.respond /xero help$/i, (res) ->
  #   res.send "Please upload receipt images in a direct message to me."
  #   debugger;

  # robot.respond /xero budgets load$/, (res) ->

  # robot.respond /xero budgets$/, (res) ->
  #   printBudgets(robot, res)


  # robot.respond /(.*)/, (res) ->
  #   if res.message?.rawMessage?.subtype != "file_share"
  #     return
  #   handleImageMessage robot, res

callXero = (res, endpoint, callback) ->
  xero.call 'GET', endpoint, null, (err, json) ->
    if err
      res.send "There was an error accessing the Xero API. Please try again."
      return
    callback(json.Response)

timeoutControl = (res, user) ->
  # This handles the 5 minute timeout for reimbursements. If a user stops responding, after 5 minutes their reimbursements stops.
  old_state = user.xero_state || '0_not_started'
  if old_state != '0_not_started'
    clearTimeout(user.xero_timeout)
  user.xero_timeout = setTimeout(() ->
    user.xero_state = '0_not_started'
    user.xero_timeout = null
  , 300000)

matchUser = (robot, res, user, email) ->
  callXero res, '/Users', (json) ->
    for xero_user in json.Users.User
      if email == xero_user.EmailAddress.toLowerCase()
        robot.brain.userForName(user.name).xero_userid = xero_user.UserID
        res.send "Successfully connected #{user['name']} to xero."
        return
    res.send "Unable to find a user with email #{email} in the xero database"

handleCancel = (robot, res, user) ->
  if user.xero_state != '0_not_started'
    clearTimeout(user.xero_timeout)
    user.xero_state = '0_not_started'

handleStartReimbursement = (robot, res, user, command, success) ->
  if command == 'start'
    res.send 'Ok! How much is this reimbursement for? Respond with something similar to `xero $12.34`.'
    success()

handleAddAmount = (robot, res, user, command, success) ->
  amount = Number(command.replace(/[^0-9\.]+/g,""))
  if amount == 0 or isNaN(amount)
    res.send 'I couldn\'t recognize that dollar amount. Please retry with something similar to `xero $12.34`'
    return
  user.xero_amount = amount
  callXero res, '/Accounts', (json) ->
    types = {}
    for type in json.Accounts.Account
      if type.ShowInExpenseClaims != 'true'
        continue
      types[type.Code] = {
        name: type.Name,
        id: type.AccountID
      }
    robot.brain.set('xero-types', types)
    result = "Select the type of expense. Please respond with `xero <id>` where `<id>` is the bolded number for that type.\n\n"
    for own code, type of types
      result += "*#{code}*: #{type.name}\n"
    res.send result
    success()

handleSelectType = (robot, res, user, command, success) ->
  types = robot.brain.get 'xero-types'
  if not types[command]?
    res.send "I didn't recognize that type. Please try again."
    return
  selected_type = types[command]
  user.xero_type = command
  res.send "Selected #{selected_type.name}. Now, write a very brief description of the expense. Please respond with `xero <description>`."
  success()

handleInputDescription = (robot, res, user, command, success) ->
  user.xero_description = command
  success()

createDraftReceipt = (res, user, success) ->
  draft = {
    Date: dateformat(new Date(), 'yyyy-mm-dd'),
    Contact: {
      ContactID: process.env.HUBOT_XERO_CONTACT_ID
    },
    LineAmountTypes: 'Inclusive',
    LineItems: {
      LineItem: {
        Description: user.xero_description,
        UnitAmount: user.xero_amount,
        Quantity: 1,
        AccountCode: user.xero_type
      }
    },
    User: {
      UserID: user.xero_userid
    }
  }
  xero.call 'PUT', '/Receipts', draft, (err, json) ->
    if err
      res.send "There was an error creating the draft receipt. Please try again."
      return
    success(json.Response.Receipts.Receipt.ReceiptID)

fs = require 'fs'

downloadSlackReceipt = (res, content_type, public_link, private_link, success) ->
  pub_secret = public_link.split("-").reverse()[0]
  private_link += "?pub_secret=" + pub_secret
  request.get public_link, (err, response, body) ->
    if err or response.statusCode != 200
      res.send "Error creating public link. Please try again."
      return
    image = new streamBuffers.WritableStreamBuffer()
    request.get(private_link).on('error', () ->
      res.send "Error downloading file from slack. Please try again."
    ).pipe(image).on('finish', () ->
      image_buffer = image.getContents()
      image_buffer.content_type = content_type
      success(image_buffer)
    )

uploadReceipt = (res, receipt_id, filename, image_buffer, success) ->
  endpoint = '/Receipts/' + receipt_id + '/Attachments/' + filename
  xero.call 'PUT', endpoint, image_buffer, (err, json) ->
    if err
      res.send "There was an error uploading the file to xero. Please try again."
      return
    success()

submitExpenseClaim = (res, userid, receipt_id, success) ->
  claim = {
    User: {
      UserID: userid
    },
    Receipts: {
      Receipt: {
        ReceiptID: receipt_id
      }
    }
  }
  xero.call 'PUT', '/ExpenseClaims', claim, (err, json) ->
    if err
      res.send "There was an error submitting the expense claim. Please try again."
      return
    success()

submitReimbursement = (robot, res, user, success) ->
  res.send "Creating draft xero receipt..."
  userid = user.xero_userid
  public_link = user.xero_receipt_public_link
  private_link = user.xero_receipt_private_link
  content_type = user.xero_receipt_content_type
  filename = private_link.split('/').reverse()[0]
  createDraftReceipt res, user, (receipt_id) ->
    res.send "Downloading receipt image from slack..."
    downloadSlackReceipt res, content_type, public_link, private_link, (image_buffer) ->
      res.send "Uploading receipt image to xero..."
      uploadReceipt res, receipt_id, filename, image_buffer, () ->
        res.send "Submitting expense claim..."
        submitExpenseClaim res, userid, receipt_id, success

stateTransition = (robot, res, user, command) ->
  if user.xero_state == '0_not_started'
    res.send "You haven't started the reimbursement process. Please direct message me an image of your receipt."
    return

  else if user.xero_state == '1_image_received'
    handleStartReimbursement robot, res, user, command, () ->
      robot.brain.userForName(user.name).xero_state = '2_reimbursement_started'

  else if user.xero_state == '2_reimbursement_started'
    handleAddAmount robot, res, user, command, () ->
      robot.brain.userForName(user.name).xero_state = '3_amount_added'

  else if user.xero_state == '3_amount_added'
    handleSelectType robot, res, user, command, () ->
      robot.brain.userForName(user.name).xero_state = '4_type_selected'

  else if user.xero_state == '4_type_selected'
    handleInputDescription robot, res, user, command, () ->
      submitReimbursement robot, res, robot.brain.userForName(user.name), () ->
        amount = robot.brain.userForName(user.name).xero_amount
        res.send "Thanks! Your reimbursement for $#{amount} has been submitted."
        handleCancel(robot, res, user)

module.exports = (robot) ->

  # Available:
  # user.xero_userid
  # user.xero_state
  # user.xero_timeout
  # user.xero_receipt_content_type
  # user.xero_receipt_public_link
  # user.xero_receipt_private_link
  # user.xero_amount
  # user.xero_type
  # user.xero_description

  if not xero?
    robot.logger.warning 'Could not load private key, not loading xero'
    return

  robot.respond /(.*)/, (res) ->
    if res.message?.rawMessage?.subtype != "file_share"
      return
    user = res.message.user
    if not user.xero_userid?
      res.send "You haven't been set up with xero yet. Try running `xero member add <your slack name>`. If that doesn't work, ask pkt-it"
      return
    if user.name != res.message.room
      return
    timeoutControl(res, user)
    user.xero_receipt_public_link = res.message.rawMessage.file.permalink_public
    user.xero_receipt_private_link = res.message.rawMessage.file.url_private
    user.xero_receipt_content_type = res.message.rawMessage.file.mimetype
    user.xero_state = '1_image_received'
    res.send "Thanks for the image. If this is a receipt, please reply with `xero start`.  If at any point you wish to cancel your progress, send `xero cancel`."

  robot.respond /xero (.+)$/, (res) ->
    command = res.match[1]
    user = res.message.user
    user.xero_state = user.xero_state or '0_not_started'
    if command == 'help'
      res.send "I can file PKT reimbursements for you. To start the process, send an image to me in a direct message."
      return
    if command.split(' ')[0] == 'member'
      return
    if not user.xero_userid?
      res.send "You haven't been set up with xero yet. Try running `xero member add <your slack name>`. If that doesn't work, ask pkt-it"
      return
    if command == 'cancel'
      handleCancel(robot, res, user)
      res.send "Reimbursement cancelled."
      return
    if user.name != res.message.room
      return
    timeoutControl(res, user)
    stateTransition(robot, res, res.message.user, command)

  robot.respond /xero member add ([a-z0-9_\-]+)($|.+$)/, (res) ->
    user = robot.brain.userForName(res.match[1])
    if not user?
      res.send "Couldn't find that user"
      return
    email = res.match[2].trim() or user['email_address']
    matchUser(robot, res, user, email)

  robot.respond /xero (delete|remove) ([a-z0-9_\-]+)$/, (res) ->
    user = robot.brain.userForName(res.match[2])
    if not user?
      res.send "Couldn't find that user"
      return
    delete user.xero_userid
    res.send "Deleted identifier"
