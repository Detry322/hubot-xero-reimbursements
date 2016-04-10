# Description:
#   Xero reimbursements
#
# Commands:
#   hubot xero help - Displays a short help message, can file reimbursements!
#   hubot xero start - Gives you a link to start the reimbursement process.
#
# Configuration:
#   HUBOT_XERO_CONSUMER_KEY
#   HUBOT_XERO_CONSUMER_SECRET
#   HUBOT_URL_BASE
#
# Notes:
#   <Hidden commands>
#   hubot xero member add <slack name> [email, optional]- Allow a user to submit reimbursements
#   hubot xero member delete <slack name> - Removes user access to submit reimbursements
#
# Author:
#   Detry322

fs = require 'fs'
request = require 'request'
Xero = require 'xero'
dateformat = require 'dateformat'
express = require 'express'

xero = try
  private_key = fs.readFileSync('xero/private_key.pem', 'ascii')
  new Xero(process.env.HUBOT_XERO_CONSUMER_KEY, process.env.HUBOT_ENV_CONSUMER_SECRET, private_key);
catch e
  null

callXero = (res, endpoint, callback) ->
  xero.call 'GET', endpoint, null, (err, json) ->
    if err
      res.send "There was an error accessing the Xero API. Please try again."
      return
    callback(json.Response)

timeoutControl = (robot, res, user) ->
  # This handles the 5 minute timeout for reimbursements. If a user stops responding, after 5 minutes their reimbursements stops.
  old_state = user.xero_state || '0_not_started'
  if old_state != '0_not_started'
    clearTimeout(user.xero_timeout)
  user.xero_timeout = setTimeout(() ->
    user.xero_state = '0_not_started'
    user.xero_timeout = null
    handleDeleteFile(robot, res.message.user.id)
  , 300000)

matchUser = (robot, res, user, email) ->
  callXero res, '/Users', (json) ->
    for xero_user in json.Users.User
      if email == xero_user.EmailAddress.toLowerCase()
        robot.brain.userForName(user.name).xero_userid = xero_user.UserID
        res.send "Successfully connected #{user['name']} to xero."
        return
    res.send "Unable to find a user with email #{email} in the xero database"

getImageBuffer = (user) ->
  buffer = fs.readFileSync(user.xero_fileloc)
  buffer.content_type = user.xero_receipt_content_type
  return buffer

handleDeleteFile = (robot, user_id) ->
  user = robot.brain.userForId(user_id)
  try
    fs.unlinkSync(user.xero_fileloc)
  catch e
    undefined
  user.xero_fileloc = null

handleCancel = (robot, res, user) ->
  if user.xero_state != '0_not_started'
    clearTimeout(user.xero_timeout)
    handleDeleteFile(robot, res.message.user.id)
    user.xero_state = '0_not_started'

handleStartReimbursement = (robot, res, user, command, success) ->
  if command == 'yes'
    res.send 'Ok! Who is this receipt from? Respond with something similar to `xero Star Market`'
    success()

handleAddFrom = (robot, res, user, command, success) ->
  user.xero_from = command
  res.send 'How much is this reimbursement for? Respond with something similar to `xero $12.34`.'
  success()

handleAddAmount = (robot, res, user, command, success) ->
  amount = Number(command.replace(/[^0-9\.]+/g,""))
  if amount == 0 or isNaN(amount)
    res.send 'I couldn\'t recognize that dollar amount. Please retry with something similar to `xero $12.34`'
    return
  user.xero_amount = amount
  callXero res, '/TrackingCategories', (json) ->
    budget = null
    for category in json.TrackingCategories.TrackingCategory
      if category.Name.toLowerCase().match("budget")?
        budget = category
        break
    tracking = {
      name: budget.Name
      budgets: {}
    }
    for option in budget.Options.Option
      shortname = option.Name.split(' ')[0].toLowerCase()
      tracking.budgets[shortname] = {
        name: option.Name
      }
    robot.brain.set('xero-budget-tracking', tracking)
    result = "Please select a budget for this receipt. Please respond with `xero <shortname>` where `<shortname>` is the bolded name for that budget.\n\n"
    for own shortname, budget of tracking.budgets
      result += "*#{shortname}*: #{budget.name}\n"
    res.send result
    success()

handleSelectBudget = (robot, res, user, command, success) ->
  tracking = robot.brain.get 'xero-budget-tracking'
  if not tracking.budgets[command]?
    res.send "I didn't recognize that budget. Please try again."
    return
  selected_budget = tracking.budgets[command]
  user.xero_tracking_category = tracking.name
  user.xero_budget = selected_budget.name
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
    result = "Selected #{selected_budget.name}. Now, select the type of expense. Please respond with `xero <id>` where `<id>` is the bolded number for that type.\n\n"
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
      Name: user.xero_from
    },
    LineAmountTypes: 'Inclusive',
    LineItems: {
      LineItem: {
        Description: user.xero_description,
        UnitAmount: user.xero_amount,
        Quantity: 1,
        AccountCode: user.xero_type,
        Tracking: {
          TrackingCategory: {
            Name: user.xero_tracking_category,
            Option: user.xero_budget
          }
        }
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
  filename = user.xero_filename
  createDraftReceipt res, user, (receipt_id) ->
    res.send "Uploading receipt image to xero..."
    image_buffer = getImageBuffer(user)
    uploadReceipt res, receipt_id, filename, image_buffer, () ->
      res.send "Submitting expense claim..."
      submitExpenseClaim res, userid, receipt_id, success

stateTransition = (robot, res, user, command) ->
  if user.xero_state == '0_not_started'
    res.send "You haven't started the reimbursement process. Type `xero start` to get started."
    return

  else if user.xero_state == '1_image_received'
    handleStartReimbursement robot, res, user, command, () ->
      robot.brain.userForName(user.name).xero_state = '2_reimbursement_started'

  else if user.xero_state == '2_reimbursement_started'
    handleAddFrom robot, res, user, command, () ->
      robot.brain.userForName(user.name).xero_state = '3_from_added'

  else if user.xero_state == '3_from_added'
    handleAddAmount robot, res, user, command, () ->
      robot.brain.userForName(user.name).xero_state = '4_amount_added'

  else if user.xero_state == '4_amount_added'
    handleSelectBudget robot, res, user, command, () ->
      robot.brain.userForName(user.name).xero_state = '5_budget_selected'

  else if user.xero_state == '5_budget_selected'
    handleSelectType robot, res, user, command, () ->
      robot.brain.userForName(user.name).xero_state = '6_type_selected'

  else if user.xero_state == '6_type_selected'
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
  # user.xero_amount
  # user.xero_tracking_category
  # user.xero_budget
  # user.xero_type
  # user.xero_description
  # user.xero_fileloc

  if not xero?
    robot.logger.warning 'Could not load private key, not loading xero'
    return

  getURL = (res) ->
    return process.env.HUBOT_URL_BASE + '/xero/' + res.message.user.id

  robot.respond /(.*)/, (res) ->
    if res.message?.rawMessage?.subtype != "file_share"
      return
    user = res.message.user
    if user.name != res.message.room
      return
    timeoutControl(robot, res, user)
    user.xero_receipt_content_type = res.message.rawMessage.file.mimetype
    res.send "Unfortunately, I can't receive images directly anymore... please go here to upload your receipt:\n\n#{getURL(res)}"

  robot.respond /xero (.+)$/, (res) ->
    command = res.match[1]
    user = res.message.user
    user.xero_state = user.xero_state or '0_not_started'
    if command.split(' ')[0] == 'member'
      return
    if not user.xero_userid?
      res.send "You haven't been set up with xero yet. Try running `xero member add <your slack name>`. Once you've done that, you can try your last command again."
      return
    if command == 'help' or command == 'start'
      res.send "I can file Xero reimbursements for you. I'll collect information in a private message, but first go upload your receipt at the following link:\n\n#{getURL(res)}"
      return
    if command == 'cancel'
      handleCancel(robot, res, user)
      res.send "Reimbursement cancelled."
      return
    if user.name != res.message.room
      return
    timeoutControl(robot, res, user)
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

  robot.router.get '/xero/:user', (req, res) ->
    user = robot.brain.userForId(req.params.user)
    if not user?
      res.send "<html><body><h1>Something went wrong...</h1></body></html>"
    else
      res.send "<html><body><form enctype='multipart/form-data' method='POST'><label for='pic'>Upload your receipt:</label><input id='pic' type='file' name='pic' accept='image/*'><input type='submit' value='submit'></form></html>"

  robot.router.post '/xero/:user', express.bodyParser(), (req, res) ->
    user = robot.brain.userForId(req.params.user)
    picture = req.files.pic
    if not user?
      res.send "<html><body><h1>Something went wrong...</h1></body></html>"
      try
        fs.unlinkSync(picture.path)
      catch e
        undefined
      return
    handleDeleteFile(robot, req.params.user)
    user.xero_receipt_content_type = picture.type
    user.xero_fileloc = picture.path
    user.xero_filename = picture.originalFilename
    user.xero_state = '1_image_received'
    robot.messageRoom user.name, 'Thanks for the receipt! Just checking, did you upload it? If not, respond with `xero cancel`. If you did upload it, respond with `xero yes`'
    res.send "Success! Please go back to slack. I've sent you a message with more instructions."

